defmodule Tightbeam.CompletionHandoffLightRailTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Assignments,
    ConnRegistry,
    DB,
    Gateway,
    Ledger,
    Model,
    NoticeBatcher,
    Org,
    Rules,
    Wakes,
    WorkItems
  }

  defmodule LaneDoorbell do
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)

    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, _session_key}, _from, parent),
      do: {:reply, :ok, parent}
  end

  setup tags do
    db = :"completion_handoff_#{System.unique_integer([:positive])}"
    scheduler = Tightbeam.WakeScheduler
    root = Path.join(System.tmp_dir!(), "handoff-files-#{System.unique_integer([:positive])}")

    prepared =
      if tags[:persistent],
        do: Tightbeam.GuardRuntimeFixture.prepare!(root, "schema_shape_runtime.exs")

    opts =
      if prepared,
        do: [
          path: Path.join(prepared.base, "state.db"),
          name: db,
          guard_inputs: [],
          payload_root: prepared.payload
        ],
        else: [path: ":memory:", name: db]

    start_supervised!({DB, opts})
    on_exit(fn -> File.rm_rf!(root) end)
    :ok = Tightbeam.Schema.ensure_all(db)

    register_hosts(db, %{
      "lab1" => %{
        ssh: nil,
        base_dir: Application.fetch_env!(:tightbeam, :base_dir),
        cli_bin: nil
      }
    })

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId,isAdmin,createdAt) VALUES ('flynn',0,1),('other',0,1)"
      )

    session(db, "notice-parent", "flynn")
    session(db, "other-parent", "flynn")
    session(db, "holder", "flynn")
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})
    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 60_000})
    law = Tightbeam.TerminalReactionFixture.load!(root, Map.keys(handlers))

    start_supervised!(
      Supervisor.child_spec(
        {Wakes, db: db, name: scheduler, tick_ms: 60_000, deliver: &deliver_wake(db, &1)},
        id: scheduler
      )
    )

    %{db: db, scheduler: scheduler, handlers: handlers, base: prepared && prepared.base, law: law}
  end

  test "a delivered finish notice starts successive fallback reminders and survives restart",
       ctx do
    stop_supervised!(ctx.scheduler)
    {parent_assignment, child_assignment, root} = completed_child(ctx)
    assert parent_assignment.state == "open"
    assert reminders(ctx.db, root.wake_id) == []

    start_scheduler(ctx.db)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert Wakes.get(ctx.db, root.wake_id).state == "fired"
    root_carrier_id = assert_delivered_carrier(ctx.db, root.wake_id)

    assert {:ok, [[root_seq, "notice-parent"]]} =
             DB.query(ctx.db, "SELECT seq,sessionKey FROM turns WHERE wakeId=?1", [
               root_carrier_id
             ])

    finish_carrier_turn!(ctx.db, root_carrier_id)

    [first] = await_pending_reminders(ctx.db, root.wake_id)
    assert String.starts_with?(first.condition_kind, "terminal-child-owner-action-")
    assert first.condition_scope == root.wake_id
    assert first.owner_user_id == "flynn"
    assert first.session_key == "notice-parent"
    assert first.assignment_id == nil
    assert first.work_item_id == nil
    assert first.created_at > 0
    assert (first.due_at - first.created_at) in 7_199_000..7_201_000
    assert root_seq > 0

    assert {:ok, {:ok, replay}} =
             DB.transaction(
               ctx.db,
               &Wakes.admit_terminal_notification_in_txn(&1, child_assignment.id)
             )

    assert replay.wake_id == root.wake_id
    assert [^first] = await_pending_reminders(ctx.db, root.wake_id)

    set_due_now(ctx.db, first.wake_id)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert Wakes.get(ctx.db, first.wake_id).state == "fired"
    first_carrier_id = assert_delivered_carrier(ctx.db, first.wake_id)
    finish_carrier_turn!(ctx.db, first_carrier_id)

    assert [second] = await_pending_reminders(ctx.db, root.wake_id),
           inspect(reminders(ctx.db, root.wake_id))

    refute second.wake_id == first.wake_id

    stop_supervised!(ctx.scheduler)
    restarted = start_scheduler(ctx.db)
    assert :ok = Wakes.fire_due(restarted)
    assert Wakes.get(ctx.db, second.wake_id).state == "pending"

    set_due_now(ctx.db, second.wake_id)
    assert :ok = Wakes.fire_due(restarted)
    assert Wakes.get(ctx.db, second.wake_id).state == "fired"
    assert assert_delivered_carrier(ctx.db, first.wake_id) == first_carrier_id
    assert_delivered_carrier(ctx.db, second.wake_id)
    [third] = await_pending_reminders(ctx.db, root.wake_id)
    refute third.wake_id in [first.wake_id, second.wake_id]
  end

  test "the turn-end sweep recovers a terminal reminder when the gateway stops after root delivery",
       ctx do
    stop_supervised!(ctx.scheduler)
    {_parent_assignment, _child_assignment, root} = completed_child(ctx)
    set_due_now(ctx.db, root.wake_id)

    assert {:ok, {:appended, _recipient, _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 root.session_key,
                 root.origin,
                 root.prompt,
                 wake_id: root.wake_id,
                 sender: root.origin,
                 target_gate: root,
                 fire_wake_in_txn: true
               )
             end)

    assert Wakes.get(ctx.db, root.wake_id).delivered_turn_seq != nil
    assert reminders(ctx.db, root.wake_id) == []

    # The stop lost the post-delivery action. After boot the recipient's turn
    # ends and the turn-end sweep acts from the delivered record.
    finish_carrier_turn!(ctx.db, root.wake_id)
    assert reminders(ctx.db, root.wake_id) == []

    sweeper =
      start_supervised!(
        {Tightbeam.Productions.BubbleSweeper, db: ctx.db, name: :completion_handoff_sweeper}
      )

    Tightbeam.Productions.BubbleSweeper.sweep_now(sweeper)

    assert [reminder] = pending_reminders(ctx.db, root.wake_id)
    assert reminder.session_key == "notice-parent"

    Tightbeam.Productions.BubbleSweeper.sweep_now(sweeper)
    assert [^reminder] = pending_reminders(ctx.db, root.wake_id)
  end

  test "a parent action reminder waits for the delivered notice turn to end", ctx do
    {_parent_assignment, _child_assignment, root} = completed_child(ctx)

    assert :ok = Wakes.fire_due(ctx.scheduler)
    root_carrier_id = assert_delivered_carrier(ctx.db, root.wake_id)
    [reminder] = pending_reminders(ctx.db, root.wake_id)

    assert {:ok, [[nil]]} =
             DB.query(
               ctx.db,
               """
               SELECT t.endedAt
               FROM wakes w
               JOIN turns t ON t.seq=w.deliveredTurnSeq
               WHERE w.wakeId=?1
               """,
               [root.wake_id]
             )

    set_due_now(ctx.db, reminder.wake_id)
    assert :ok = Wakes.fire_due(ctx.scheduler)

    assert Wakes.get(ctx.db, reminder.wake_id).fired_at == nil
    assert NoticeBatcher.source_refs(ctx.db, reminder.wake_id) == []

    finish_carrier_turn!(ctx.db, root_carrier_id)

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               """
               SELECT count(*)
               FROM wakes w
               JOIN turns t ON t.seq=w.deliveredTurnSeq
               WHERE w.wakeId=?1 AND t.endedAt IS NOT NULL
               """,
               [root.wake_id]
             )

    assert :ok = Wakes.fire_due(ctx.scheduler)

    assert Wakes.get(ctx.db, reminder.wake_id).state == "fired"
    assert_delivered_carrier(ctx.db, reminder.wake_id)
  end

  test "a retired opener is routed to Main when the finish notice is stored", ctx do
    stop_supervised!(ctx.scheduler)
    item = create_work_item(ctx, "completion with retired opener")
    personal = Org.personal_session_key("flynn")
    session(ctx.db, personal, "flynn")

    child_assignment =
      handle(
        ctx,
        "assign",
        assign_call({:session, "notice-parent"}, "holder", "child task", item.id,
          effect_kind: "coordination"
        )
      )

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='notice-parent'")

    assert %{assignment: %{state: "closed"}} =
             handle(
               ctx,
               "attest",
               attest_call({:session, "holder"}, child_assignment.id, "completion")
             )

    [root] = terminal_notices(ctx.db)
    assert root.state == "pending"
    assert root.session_key == personal
    assert reminders(ctx.db, root.wake_id) == []

    start_scheduler(ctx.db)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert Wakes.get(ctx.db, root.wake_id).state == "fired"
    assert_delivered_carrier(ctx.db, root.wake_id)
    assert reminders(ctx.db, root.wake_id) == []
  end

  test "a parent with no open assignment gets the initial notice but no reminder rail", ctx do
    {nil, child_assignment, root} = completed_child(ctx, with_parent_destination: false)

    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert Wakes.get(ctx.db, root.wake_id).state == "fired"
    assert_delivered_carrier(ctx.db, root.wake_id)
    assert reminders(ctx.db, root.wake_id) == []

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM assignments WHERE holderKey='notice-parent' AND state='open'"
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM attests WHERE bySession='notice-parent' AND kind='progress' AND note LIKE 'completion-handoff-action %'"
             )

    _later_assignment =
      handle(
        ctx,
        "assign",
        assign_call(
          {:session, "other-parent"},
          "notice-parent",
          "later parent work",
          child_assignment.workItemId
        )
      )

    assert {:ok, {:ok, replay}} =
             DB.transaction(
               ctx.db,
               &Wakes.admit_terminal_notification_in_txn(&1, child_assignment.id)
             )

    assert replay.wake_id == root.wake_id
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert reminders(ctx.db, root.wake_id) == []
  end

  test "a pending reminder remains until the recipient closes their last open assignment",
       ctx do
    {parent_assignment, _child_assignment, root} =
      completed_child(ctx, parent_opener: "other-parent")

    additional_item = create_work_item(ctx, "additional parent work")

    additional_assignment =
      handle(
        ctx,
        "assign",
        assign_call(
          {:session, "other-parent"},
          "notice-parent",
          "additional parent work",
          additional_item.id,
          effect_kind: "coordination"
        )
      )

    assert :ok = Wakes.fire_due(ctx.scheduler)
    [pending] = pending_reminders(ctx.db, root.wake_id)

    assert %{assignment: %{state: "closed"}, attest: %{kind: "completion"}} =
             handle(
               ctx,
               "attest",
               attest_call({:session, "notice-parent"}, parent_assignment.id, "completion")
             )

    assert Wakes.get(ctx.db, pending.wake_id).state == "pending"
    assert pending_reminders(ctx.db, root.wake_id) == [pending]

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM wake_cancellations WHERE wakeId=?1",
               [pending.wake_id]
             )

    assert %{assignment: %{state: "closed"}, attest: %{kind: "completion"}} =
             handle(
               ctx,
               "attest",
               attest_call(
                 {:session, "notice-parent"},
                 additional_assignment.id,
                 "completion"
               )
             )

    assert Wakes.get(ctx.db, pending.wake_id).state == "canceled"
    assert turn_count(ctx.db, pending.wake_id) == 0
    assert pending_reminders(ctx.db, root.wake_id) == []

    assert {:ok,
            [
              [
                "obligation_disposed",
                "assignment_transition",
                assignment_id,
                "disposition",
                "assignment_transition",
                disposition_id
              ]
            ]} =
             DB.query(
               ctx.db,
               "SELECT reasonKind,causalSourceKind,causalSourceId,outcomeKind,dispositionKind,dispositionId FROM wake_cancellations WHERE wakeId=?1",
               [pending.wake_id]
             )

    assert assignment_id == additional_assignment.id
    assert disposition_id == additional_assignment.id
  end

  test "a pending reminder is canceled in the transaction that closes the parent's only open assignment",
       ctx do
    {parent_assignment, _child_assignment, root} =
      completed_child(ctx, parent_opener: "other-parent")

    assert :ok = Wakes.fire_due(ctx.scheduler)
    [pending] = pending_reminders(ctx.db, root.wake_id)

    assert %{assignment: %{state: "closed"}, attest: %{kind: "completion"}} =
             handle(
               ctx,
               "attest",
               attest_call({:session, "notice-parent"}, parent_assignment.id, "completion")
             )

    assert Wakes.get(ctx.db, pending.wake_id).state == "canceled"
    assert turn_count(ctx.db, pending.wake_id) == 0
    assert pending_reminders(ctx.db, root.wake_id) == []

    assert {:ok,
            [
              [
                "obligation_disposed",
                "assignment_transition",
                assignment_id,
                "disposition",
                "assignment_transition",
                disposition_id
              ]
            ]} =
             DB.query(
               ctx.db,
               "SELECT reasonKind,causalSourceKind,causalSourceId,outcomeKind,dispositionKind,dispositionId FROM wake_cancellations WHERE wakeId=?1",
               [pending.wake_id]
             )

    assert assignment_id == parent_assignment.id
    assert disposition_id == parent_assignment.id
  end

  test "a delivered reminder does not rearm after the parent loses its last open assignment",
       ctx do
    {parent_assignment, _child_assignment, root} =
      completed_child(ctx, parent_opener: "other-parent")

    assert :ok = Wakes.fire_due(ctx.scheduler)
    root_carrier_id = hd(NoticeBatcher.source_refs(ctx.db, root.wake_id)).delivery_wake_id
    finish_carrier_turn!(ctx.db, root_carrier_id)
    [first] = pending_reminders(ctx.db, root.wake_id)
    set_due_now(ctx.db, first.wake_id)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert Wakes.get(ctx.db, first.wake_id).state == "fired"
    assert_delivered_carrier(ctx.db, first.wake_id)

    assert [successor] = pending_reminders(ctx.db, root.wake_id),
           inspect(reminders(ctx.db, root.wake_id))

    assert %{assignment: %{state: "closed"}} =
             handle(
               ctx,
               "attest",
               attest_call({:session, "notice-parent"}, parent_assignment.id, "completion")
             )

    assert Wakes.get(ctx.db, successor.wake_id).state == "canceled"
    assert turn_count(ctx.db, successor.wake_id) == 0
    assert pending_reminders(ctx.db, root.wake_id) == []
    assert length(reminders(ctx.db, root.wake_id)) == 2
  end

  test "loss of recipient eligibility cancels a reminder and retains root delivery history",
       ctx do
    {_parent_assignment, _child_assignment, root} = completed_child(ctx)

    assert :ok = Wakes.fire_due(ctx.scheduler)
    root_carrier_id = assert_delivered_carrier(ctx.db, root.wake_id)
    finish_carrier_turn!(ctx.db, root_carrier_id)
    # The source-owning scheduler handles the post-commit delivery record in
    # its mailbox after the carrier transaction returns. A synchronous pass is
    # the barrier before reading the reminder it records.
    assert :ok = Wakes.fire_due(ctx.scheduler)
    [reminder] = pending_reminders(ctx.db, root.wake_id)
    delivered_root = Wakes.get(ctx.db, root.wake_id)
    assert is_integer(delivered_root.delivered_turn_seq)

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE sessions SET state='retired' WHERE sessionKey='notice-parent'"
             )

    assert %{deliveryOwnerSessionKey: "other-parent"} =
             handle(
               ctx,
               "work-item-update",
               call("work-item-update", {:user, "flynn"}, nil, %{
                 work_item_id: delivered_root.work_item_id,
                 delivery_owner_session_key: "other-parent"
               })
             )

    assert %{state: "canceled", session_key: "notice-parent", prompt: prompt, due_at: due_at} =
             Wakes.get(ctx.db, reminder.wake_id)

    assert prompt == reminder.prompt
    assert due_at == reminder.due_at

    assert %{state: "fired", session_key: "notice-parent", delivered_turn_seq: delivered_seq} =
             Wakes.get(ctx.db, root.wake_id)

    assert delivered_seq == delivered_root.delivered_turn_seq
  end

  test "a valid action receipt remains stopping evidence after its assignment closes", ctx do
    {parent_assignment, child_assignment, root} =
      completed_child(ctx, parent_opener: "other-parent")

    assert :ok = Wakes.fire_due(ctx.scheduler)
    [pending] = pending_reminders(ctx.db, root.wake_id)
    note = action_note(child_assignment.id, root, "kept", "kept the child for its next owner")

    assert %{attest: %{id: attest_id, kind: "progress"}} =
             handle(
               ctx,
               "attest",
               progress_call({:session, "notice-parent"}, parent_assignment.id, note)
             )

    assert Wakes.get(ctx.db, pending.wake_id).state == "canceled"

    assert %{assignment: %{state: "closed"}} =
             handle(
               ctx,
               "attest",
               attest_call({:session, "notice-parent"}, parent_assignment.id, "completion")
             )

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.terminal_notice_delivered_in_txn(txn, root.wake_id, "notice-parent")
             end)

    assert pending_reminders(ctx.db, root.wake_id) == []

    assert {:ok, [["superseded", "progress_attest", ^attest_id, "no_replacement"]]} =
             DB.query(
               ctx.db,
               "SELECT reasonKind,causalSourceKind,causalSourceId,outcomeKind FROM wake_cancellations WHERE wakeId=?1",
               [pending.wake_id]
             )
  end

  test "a multi-line action detail still matches the documented note shape", ctx do
    {parent_assignment, child_assignment, root} =
      completed_child(ctx, parent_opener: "other-parent")

    assert :ok = Wakes.fire_due(ctx.scheduler)
    [pending] = pending_reminders(ctx.db, root.wake_id)

    detail = "kept the child for its next owner.\n\nSecond paragraph with more detail."
    note = action_note(child_assignment.id, root, "kept", detail)

    assert %{attest: %{kind: "progress"}} =
             handle(
               ctx,
               "attest",
               progress_call({:session, "notice-parent"}, parent_assignment.id, note)
             )

    assert Wakes.get(ctx.db, pending.wake_id).state == "canceled"
  end

  test "the shipped parent directive appears in composed guidance for both harnesses", _ctx do
    base =
      Path.join(
        System.tmp_dir!(),
        "completion-handoff-guidance-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(base) end)

    packaged_manual =
      Application.app_dir(:tightbeam, "priv/guidance/operating-manual.md")
      |> File.read!()
      |> String.replace(~r/\s+/, " ")

    assert packaged_manual =~ "copy `assignment_id`, `source_kind`, and `source_token`"

    assert packaged_manual =~
             "completion-handoff-action <assignment_id> <source_kind> <source_token> <kept|parked|retired>: <what you did>"

    assert packaged_manual =~ "use the plain ASCII colon after the outcome"
    refute packaged_manual =~ "preserve the literal em dash"
    assert packaged_manual =~ "No reminder is scheduled"

    assert Regex.match?(
             ~r/No reminder is scheduled without a lawful\s+progress-attest destination/,
             packaged_manual
           )

    assert packaged_manual =~ "Do not self-assign or fabricate an acknowledgment"

    :initialized = Tightbeam.Identity.init!(base)
    revision = Tightbeam.Identity.live_revision!(base)

    for harness <- [:codex, :claude] do
      snapshot = Tightbeam.Identity.snapshot_at!(base, revision, "default", harness)
      guidance = String.replace(snapshot.guidance, ~r/\s+/, " ")
      assert guidance =~ "copy `assignment_id`, `source_kind`, and `source_token`"

      assert guidance =~
               "completion-handoff-action <assignment_id> <source_kind> <source_token> <kept|parked|retired>: <what you did>"

      assert guidance =~ "use the plain ASCII colon after the outcome"
      refute guidance =~ "preserve the literal em dash"
      assert guidance =~ "No reminder is scheduled"

      assert Regex.match?(
               ~r/No reminder is scheduled without a lawful\s+progress-attest destination/,
               guidance
             )

      assert guidance =~ "Do not self-assign or fabricate an acknowledgment"
      refute Regex.match?(~r/^#include/m, snapshot.guidance)
    end
  end

  test "only the responsible parent's exact action attest for this child stops the chain", ctx do
    {parent_assignment, child_assignment, root} = completed_child(ctx)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    [first] = pending_reminders(ctx.db, root.wake_id)
    set_due_now(ctx.db, first.wake_id)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    [pending] = pending_reminders(ctx.db, root.wake_id)

    wrong_parent_note = action_note(child_assignment.id, root, "kept", "kept the child")

    other_assignment =
      handle(
        ctx,
        "assign",
        assign_call(
          {:session, "other-parent"},
          "other-parent",
          "other parent's work",
          child_assignment.workItemId
        )
      )

    assert %{attest: %{kind: "progress"}} =
             handle(
               ctx,
               "attest",
               progress_call({:session, "other-parent"}, other_assignment.id, wrong_parent_note)
             )

    wrong_child = action_note(child_assignment.id <> "-other", root, "kept", "kept another child")

    assert %{attest: %{kind: "progress"}} =
             handle(
               ctx,
               "attest",
               progress_call({:session, "notice-parent"}, parent_assignment.id, wrong_child)
             )

    wrong_note = "completion-handoff-action #{child_assignment.id} attest #{root.wake_id} kept"

    assert %{attest: %{kind: "progress"}} =
             handle(
               ctx,
               "attest",
               progress_call({:session, "notice-parent"}, parent_assignment.id, wrong_note)
             )

    wrong_occurrence =
      "completion-handoff-action #{child_assignment.id} attest #{root.wake_id} kept: kept the child"

    assert %{attest: %{kind: "progress"}} =
             handle(
               ctx,
               "attest",
               progress_call({:session, "notice-parent"}, parent_assignment.id, wrong_occurrence)
             )

    assert [^pending] = pending_reminders(ctx.db, root.wake_id)

    valid_note = action_note(child_assignment.id, root, "parked", "parked the finished child")

    assert %{attest: %{id: attest_id, kind: "progress"}} =
             handle(
               ctx,
               "attest",
               progress_call({:session, "notice-parent"}, parent_assignment.id, valid_note)
             )

    assert Wakes.get(ctx.db, pending.wake_id).state == "canceled"
    assert pending_reminders(ctx.db, root.wake_id) == []

    assert {:ok, [["superseded", "progress_attest", ^attest_id, "no_replacement"]]} =
             DB.query(
               ctx.db,
               "SELECT reasonKind,causalSourceKind,causalSourceId,outcomeKind FROM wake_cancellations WHERE wakeId=?1",
               [pending.wake_id]
             )

    before = turn_count(ctx.db, pending.wake_id)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert turn_count(ctx.db, pending.wake_id) == before
  end

  test "an exact retired receipt stops the reminder without asserting physical retirement", ctx do
    {parent, child, root} = completed_child(ctx)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    finish_carrier_turn!(ctx.db, assert_delivered_carrier(ctx.db, root.wake_id))
    [pending] = await_pending_reminders(ctx.db, root.wake_id)
    note = action_note(child.id, root, "retired", "requested retirement")

    assert %{attest: %{kind: "progress"}} =
             handle(ctx, "attest", progress_call({:session, "notice-parent"}, parent.id, note))

    assert Wakes.get(ctx.db, pending.wake_id).state == "canceled"

    assert {:ok, [["active"]]} =
             DB.query(ctx.db, "SELECT state FROM sessions WHERE sessionKey='holder'")

    assert turn_count(ctx.db, pending.wake_id) == 0
  end

  @tag persistent: true
  test "published terminal wording uses current activity and stored identity still accepts an old receipt",
       ctx do
    alias Tightbeam.{Identity, Reminders}
    Identity.init!(ctx.base)
    {:ok, candidate} = Identity.learn!(ctx.base, "agentic-engineering", "test")
    {:ok, _} = Identity.publish_live!(ctx.base, candidate)
    {parent, child, root} = completed_child(ctx)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    carrier = assert_delivered_carrier(ctx.db, root.wake_id)
    finish_carrier_turn!(ctx.db, carrier)
    [pending] = await_pending_reminders(ctx.db, root.wake_id)
    # Old prompt bytes have no role in the persisted completion identity.
    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE wakes SET prompt='Earlier release reminder text' WHERE wakeId=?1",
        [pending.wake_id]
      )

    dir = Path.join(ctx.base, "identity")

    File.write!(
      Path.join(dir, "reminders/terminal-action.md"),
      "Current {child_session_state}; activity {your_last_activity}; finished {child_finished}"
    )

    {_, 0} = System.cmd("git", ["add", "-A"], cd: dir)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Test",
          "-c",
          "user.email=test@example.invalid",
          "commit",
          "-m",
          "Edit reminder"
        ],
        cd: dir
      )

    {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)

    {:ok, _} =
      Identity.publish_live!(ctx.base, %{
        candidate_revision: String.trim(revision),
        expected_prior: Identity.live_revision!(ctx.base)
      })

    other =
      handle(ctx, "assign", assign_call({:user, "flynn"}, "notice-parent", "other work", nil))

    %{attest: attest} =
      handle(
        ctx,
        "attest",
        progress_call({:session, "notice-parent"}, other.id, "material result")
      )

    set_due_now(ctx.db, pending.wake_id)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    prompt = Wakes.get(ctx.db, pending.wake_id).prompt

    assert prompt =~
             "Current active; activity " <>
               Reminders.activity(attest.ts, System.system_time(:millisecond))

    finish_carrier_turn!(ctx.db, assert_delivered_carrier(ctx.db, pending.wake_id))
    [successor] = await_pending_reminders(ctx.db, root.wake_id)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE wakes SET prompt='Earlier release reminder text' WHERE wakeId=?1",
        [successor.wake_id]
      )

    note = action_note(child.id, root, "kept", "kept for further work")

    assert %{attest: %{kind: "progress"}} =
             handle(ctx, "attest", progress_call({:session, "notice-parent"}, parent.id, note))

    assert Wakes.get(ctx.db, successor.wake_id).state == "canceled"
  end

  test "a malformed action note does not suppress the first terminal reminder", ctx do
    {parent_assignment, child_assignment, root} = completed_child(ctx)
    [source_kind, source_token] = terminal_source(root.prompt)

    malformed =
      "completion-handoff-action #{child_assignment.id} #{source_kind} #{source_token} " <>
        "kept without the required colon and detail"

    assert %{attest: %{kind: "progress"}} =
             handle(
               ctx,
               "attest",
               progress_call({:session, "notice-parent"}, parent_assignment.id, malformed)
             )

    assert :ok = Wakes.fire_due(ctx.scheduler)
    root_carrier_id = assert_delivered_carrier(ctx.db, root.wake_id)
    finish_carrier_turn!(ctx.db, root_carrier_id)

    assert [reminder] = pending_reminders(ctx.db, root.wake_id)
    assert reminder.session_key == "notice-parent"
  end

  test "a malformed indexed candidate does not hide a later valid action", ctx do
    {parent_assignment, child_assignment, root} = completed_child(ctx)
    [source_kind, source_token] = terminal_source(root.prompt)

    malformed =
      "completion-handoff-action #{child_assignment.id} #{source_kind} #{source_token} " <>
        "parked without the required colon and detail"

    assert %{attest: %{kind: "progress"}} =
             handle(
               ctx,
               "attest",
               progress_call({:session, "notice-parent"}, parent_assignment.id, malformed)
             )

    {:ok, _} = DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='holder'")
    valid = action_note(child_assignment.id, root, "retired", "retired the completed child")

    assert %{attest: %{kind: "progress"}} =
             handle(
               ctx,
               "attest",
               progress_call({:session, "notice-parent"}, parent_assignment.id, valid)
             )

    assert :ok = Wakes.fire_due(ctx.scheduler)
    root_carrier_id = assert_delivered_carrier(ctx.db, root.wake_id)
    finish_carrier_turn!(ctx.db, root_carrier_id)

    assert pending_reminders(ctx.db, root.wake_id) == []
  end

  test "an action at the fallback boundary either stops the pending wake or cancels its successor",
       ctx do
    {parent_assignment, child_assignment, root} = completed_child(ctx)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    root_carrier_id = hd(NoticeBatcher.source_refs(ctx.db, root.wake_id)).delivery_wake_id
    finish_carrier_turn!(ctx.db, root_carrier_id)
    [pending] = pending_reminders(ctx.db, root.wake_id)
    set_due_now(ctx.db, pending.wake_id)

    action = action_note(child_assignment.id, root, "kept", "kept the child for the next handoff")

    assert %{attest: %{kind: "progress"}} =
             handle(
               ctx,
               "attest",
               progress_call({:session, "notice-parent"}, parent_assignment.id, action)
             )

    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert pending_reminders(ctx.db, root.wake_id) == []
    assert Wakes.get(ctx.db, pending.wake_id).state == "canceled"
    assert turn_count(ctx.db, pending.wake_id) == 0
  end

  test "a reminder that fires first leaves one historical delivery and the action cancels its successor",
       ctx do
    {parent_assignment, child_assignment, root} = completed_child(ctx)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    root_carrier_id = hd(NoticeBatcher.source_refs(ctx.db, root.wake_id)).delivery_wake_id
    finish_carrier_turn!(ctx.db, root_carrier_id)
    [pending] = await_pending_reminders(ctx.db, root.wake_id)
    set_due_now(ctx.db, pending.wake_id)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    [successor] = await_pending_reminders(ctx.db, root.wake_id)
    assert_delivered_carrier(ctx.db, pending.wake_id)

    {:ok, _} = DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='holder'")
    action = action_note(child_assignment.id, root, "retired", "retired the idle child session")

    assert %{attest: %{kind: "progress"}} =
             handle(
               ctx,
               "attest",
               progress_call({:session, "notice-parent"}, parent_assignment.id, action)
             )

    assert Wakes.get(ctx.db, successor.wake_id).state == "canceled"
    assert pending_reminders(ctx.db, root.wake_id) == []
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert turn_count(ctx.db, successor.wake_id) == 0
  end

  test "without elected rails a terminal command commits quietly and is never replayed", ctx do
    item = create_work_item(ctx, "quiet terminal")

    child =
      handle(
        ctx,
        "assign",
        assign_call({:session, "notice-parent"}, "holder", "child", item.id,
          effect_kind: "coordination"
        )
      )

    Rules.load!(Path.join(ctx.law, "empty"), Map.keys(ctx.handlers))

    assert %{assignment: %{state: "closed"}} =
             handle(ctx, "attest", attest_call({:session, "holder"}, child.id, "completion"))

    assert terminal_notices(ctx.db) == []
    Rules.load!(ctx.law, Map.keys(ctx.handlers))
    assert :ok = Tightbeam.RowReactions.recover(ctx.db)

    assert {:ok, {:ok, nil}} =
             DB.transaction(
               ctx.db,
               &Wakes.admit_terminal_notification_in_txn(&1, child.id)
             )

    assert terminal_notices(ctx.db) == []
  end

  test "removing a rail withdraws pending output and restoring it cannot replay delivery", ctx do
    stop_supervised!(ctx.scheduler)
    {_parent, _child, root} = completed_child(ctx)
    Rules.load!(Path.join(ctx.law, "empty"), Map.keys(ctx.handlers))
    assert :ok = Tightbeam.RowReactions.recover(ctx.db)

    assert Wakes.get(ctx.db, root.wake_id).state == "canceled",
           inspect(DB.query(ctx.db, "SELECT status,lastError FROM row_reaction_actions"))

    assert {:ok, [["superseded"]]} =
             DB.query(ctx.db, "SELECT reasonKind FROM wake_cancellations WHERE wakeId=?1", [
               root.wake_id
             ])

    Rules.load!(ctx.law, Map.keys(ctx.handlers))
    assert :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert Wakes.get(ctx.db, root.wake_id).state == "canceled"
    assert turn_count(ctx.db, root.wake_id) == 0
    assert length(terminal_notices(ctx.db)) == 1
  end

  test "the elected reminder deadline controls pending work without changing identity", ctx do
    {_parent, _child, root} = completed_child(ctx)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    [reminder] = pending_reminders(ctx.db, root.wake_id)
    path = Path.join(ctx.law, "identity/rules/row-reaction-terminal-action.toml")
    File.write!(path, String.replace(File.read!(path), "7200000", "10800000"))
    Rules.load!(ctx.law, Map.keys(ctx.handlers))
    assert :ok = Tightbeam.RowReactions.recover(ctx.db)
    [updated] = pending_reminders(ctx.db, root.wake_id)
    assert updated.wake_id == reminder.wake_id
    assert updated.due_at == reminder.due_at + 3_600_000
    assert Wakes.get(ctx.db, root.wake_id).delivered_turn_seq != nil
  end

  test "a failed effect admission rolls back the terminal write and its evidence", ctx do
    item = create_work_item(ctx, "atomic terminal")

    child =
      handle(
        ctx,
        "assign",
        assign_call({:session, "notice-parent"}, "holder", "child", item.id,
          effect_kind: "coordination"
        )
      )

    assert {:ok, _} =
             DB.query(ctx.db, """
             CREATE TRIGGER reject_reaction BEFORE INSERT ON row_reaction_actions
             BEGIN SELECT RAISE(ABORT, 'injected admission failure'); END
             """)

    assert_raise DB.Error, ~r/injected admission failure/, fn ->
      ctx.handlers["attest"].(attest_call({:session, "holder"}, child.id, "completion"))
    end

    assert {:ok, [["open"]]} =
             DB.query(ctx.db, "SELECT state FROM assignments WHERE id=?1", [child.id])

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM attests WHERE assignmentId=?1 AND kind='completion'",
               [child.id]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM row_reaction_events WHERE json_extract(event,'$.terminal.assignment_id')=?1",
               [child.id]
             )

    assert terminal_notices(ctx.db) == []
  end

  test "cutover adopts pending output once and keeps its terminal occurrence identity", ctx do
    stop_supervised!(ctx.scheduler)
    {_parent, child, root} = completed_child(ctx)
    forget_reaction_ledger!(ctx.db)
    assert :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert [adopted] = terminal_notices(ctx.db)
    assert adopted.wake_id == root.wake_id
    assert adopted.due_at == root.due_at

    assert {:ok, {:ok, replay}} =
             DB.transaction(
               ctx.db,
               &Wakes.admit_terminal_notification_in_txn(&1, child.id)
             )

    assert replay.wake_id == root.wake_id
    assert :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert length(terminal_notices(ctx.db)) == 1
    start_scheduler(ctx.db)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert_delivered_carrier(ctx.db, root.wake_id)
    assert [_] = pending_reminders(ctx.db, root.wake_id)
  end

  test "cutover keeps an accepted delivery terminal and adopts only its pending successor", ctx do
    {_parent, _child, root} = completed_child(ctx)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    carrier = assert_delivered_carrier(ctx.db, root.wake_id)
    [reminder] = pending_reminders(ctx.db, root.wake_id)
    stop_supervised!(ctx.scheduler)
    forget_reaction_ledger!(ctx.db)
    assert :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert assert_delivered_carrier(ctx.db, root.wake_id) == carrier
    assert [adopted] = pending_reminders(ctx.db, root.wake_id)
    assert adopted.wake_id == reminder.wake_id
    assert adopted.due_at == reminder.due_at
    assert length(terminal_notices(ctx.db)) == 1
  end

  test "unproven historical output is held with a reason while other pending output proceeds",
       ctx do
    stop_supervised!(ctx.scheduler)
    {_parent, _child, root} = completed_child(ctx)

    unknown =
      Wakes.schedule(ctx.db, %{
        wake_id: "unknown-historical-output",
        session_key: "other-parent",
        owner_user_id: "flynn",
        origin: "process:tightbeam",
        prompt: "Historical output with no provable source",
        due_at: System.system_time(:millisecond),
        obligation_ref: "terminal-child-owner-notification:unknown-assignment"
      })

    forget_reaction_ledger!(ctx.db)
    assert :ok = Tightbeam.RowReactions.recover(ctx.db)

    assert {:ok, [["held", reason]]} =
             DB.query(
               ctx.db,
               "SELECT status,lastError FROM row_reaction_actions WHERE json_extract(result,'$.wake_id')=?1",
               [unknown.wake_id]
             )

    assert reason =~ "unproven"
    start_scheduler(ctx.db)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert_delivered_carrier(ctx.db, root.wake_id)
    assert Wakes.get(ctx.db, unknown.wake_id).state == "pending"
    assert turn_count(ctx.db, unknown.wake_id) == 0
  end

  test "an undelivered intent resumes once through transport lineage when its recipient becomes eligible",
       ctx do
    stop_supervised!(ctx.scheduler)
    item = create_work_item(ctx, "recipient recovery")

    child =
      handle(
        ctx,
        "assign",
        assign_call({:user, "flynn"}, "holder", "child", item.id, effect_kind: "coordination")
      )

    assert %{assignment: %{state: "closed"}} =
             handle(ctx, "attest", attest_call({:session, "holder"}, child.id, "completion"))

    [failed] = terminal_notices(ctx.db)
    assert failed.state == "canceled"

    assert {:ok, [[action_id, "pending", "undelivered"]]} =
             DB.query(
               ctx.db,
               "SELECT id,status,json_extract(result,'$.delivery') FROM row_reaction_actions"
             )

    for _ <- 1..2, do: assert(:ok == Tightbeam.RowReactions.recover(ctx.db))
    assert [^failed] = terminal_notices(ctx.db)

    personal = Org.personal_session_key("flynn")
    session(ctx.db, personal, "flynn")

    assert %{deliveryOwnerSessionKey: ^personal} =
             handle(
               ctx,
               "work-item-update",
               call("work-item-update", {:user, "flynn"}, nil, %{
                 work_item_id: item.id,
                 delivery_owner_session_key: personal
               })
             )

    assert {:ok, [[^action_id, "pending", retry_id, intent_id]]} =
             DB.query(
               ctx.db,
               "SELECT id,status,json_extract(result,'$.wake_id'),json_extract(result,'$.intent_wake_id') FROM row_reaction_actions"
             )

    assert intent_id == failed.wake_id
    refute retry_id == failed.wake_id
    assert %{session_key: ^personal, state: "pending"} = Wakes.get(ctx.db, retry_id)

    assert {:ok, [[root_id, predecessor, 1]]} =
             DB.query(
               ctx.db,
               "SELECT rootWakeId,predecessorWakeId,attempt FROM wake_retry_attempts WHERE wakeId=?1",
               [retry_id]
             )

    assert root_id == failed.wake_id
    assert predecessor == failed.wake_id
    assert :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert length(terminal_notices(ctx.db)) == 2
    start_scheduler(ctx.db)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert_delivered_carrier(ctx.db, retry_id)
    assert :ok = Tightbeam.RowReactions.recover(ctx.db)

    assert {:ok, [[^action_id, "accepted", "delivered"]]} =
             DB.query(
               ctx.db,
               "SELECT id,status,json_extract(result,'$.delivery') FROM row_reaction_actions WHERE id=?1",
               [action_id]
             )

    assert {:ok, {:ok, %{wake_id: ^retry_id, state: "fired"}}} =
             DB.transaction(
               ctx.db,
               &Wakes.admit_terminal_notification_in_txn(&1, child.id)
             )

    assert length(terminal_notices(ctx.db)) == 2
    assert Wakes.get(ctx.db, failed.wake_id).state == "canceled"
    assert turn_count(ctx.db, failed.wake_id) == 0

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM lifecycle_events WHERE kind='wake_undeliverable' AND subject=?1",
               [failed.wake_id]
             )
  end

  test "receipt lookup bounds growing progress history and ordinary progress does not reconcile reminders",
       ctx do
    {parent, child, root} = completed_child(ctx)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    [pending] = pending_reminders(ctx.db, root.wake_id)

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        WITH RECURSIVE history(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM history WHERE n<3000)
        INSERT INTO attests(id,assignmentId,kind,bySession,note,ts)
        SELECT 'history-'||n,?1,'progress','notice-parent',
          'completion-handoff-action unrelated-child attest unrelated-source kept: historical work',n
        FROM history
        """,
        [parent.id]
      )

    {:ok, before_attempts} =
      DB.query(
        ctx.db,
        "SELECT attempts FROM row_reaction_actions WHERE json_extract(result,'$.wake_id')=?1",
        [pending.wake_id]
      )

    assert %{attest: %{kind: "progress"}} =
             handle(
               ctx,
               "attest",
               progress_call({:session, "notice-parent"}, parent.id, "ordinary material progress")
             )

    assert {:ok, ^before_attempts} =
             DB.query(
               ctx.db,
               "SELECT attempts FROM row_reaction_actions WHERE json_extract(result,'$.wake_id')=?1",
               [pending.wake_id]
             )

    [kind, token] = terminal_source(root.prompt)
    prefix = "completion-handoff-action #{child.id} #{kind} #{token} "

    assert %{attest: %{kind: "progress"}} =
             handle(
               ctx,
               "attest",
               progress_call(
                 {:session, "notice-parent"},
                 parent.id,
                 prefix <> "kept without a colon"
               )
             )

    assert {:ok, facts} =
             DB.transaction(ctx.db, fn txn ->
               event = Tightbeam.RowReactions.delivery_event(txn, root.wake_id)
               Tightbeam.RowReactions.Snapshot.current(txn, event, %{})
             end)

    assert length(facts["attests"]) == 1
    assert hd(facts["attests"])["disposition"] == nil

    assert {:ok, plan} =
             DB.query(
               ctx.db,
               """
               EXPLAIN QUERY PLAN SELECT id,note FROM attests INDEXED BY row_reaction_receipt_candidates
               WHERE bySession=?1 AND kind='progress' AND note>=?2 AND note<?3
               """,
               ["notice-parent", prefix, String.trim_trailing(prefix, " ") <> "!"]
             )

    assert Enum.any?(plan, fn row ->
             detail = List.last(row)

             String.contains?(
               detail,
               "SEARCH attests USING INDEX row_reaction_receipt_candidates"
             ) and
               String.contains?(detail, "note>?") and String.contains?(detail, "note<?")
           end)

    assert %{attest: %{kind: "progress"}} =
             handle(
               ctx,
               "attest",
               progress_call(
                 {:session, "notice-parent"},
                 parent.id,
                 prefix <> "kept: retained this child"
               )
             )

    assert Wakes.get(ctx.db, pending.wake_id).state == "canceled"

    assert {:ok, facts} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.RowReactions.Snapshot.current(
                 txn,
                 Tightbeam.RowReactions.delivery_event(txn, root.wake_id),
                 %{}
               )
             end)

    assert length(facts["attests"]) == 2
    assert Enum.count(facts["attests"], &is_map(&1["disposition"])) == 1
  end

  defp forget_reaction_ledger!(db) do
    # Simulate the declared pre-cutover population: the original wake, source
    # occurrence and delivery receipts remain, with no reaction ledger yet.
    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Tightbeam.DB.Txn.q(txn, "DELETE FROM row_reaction_actions")
               Tightbeam.DB.Txn.q(txn, "DELETE FROM row_reaction_events")
               Tightbeam.DB.Txn.q(txn, "DELETE FROM row_reaction_cutovers")
               :ok
             end)
  end

  defp completed_child(ctx, opts \\ []) do
    item = create_work_item(ctx, "completion handoff")

    parent_assignment =
      if Keyword.get(opts, :with_parent_destination, true) do
        parent_opener = Keyword.get(opts, :parent_opener, "notice-parent")

        handle(
          ctx,
          "assign",
          assign_call(
            {:session, parent_opener},
            "notice-parent",
            "parent coordination",
            item.id,
            effect_kind: "coordination"
          )
        )
      end

    child_assignment =
      handle(
        ctx,
        "assign",
        assign_call({:session, "notice-parent"}, "holder", "child task", item.id,
          effect_kind: "coordination"
        )
      )

    assert %{assignment: %{state: "closed"}, attest: %{kind: "completion", id: source_token}} =
             handle(
               ctx,
               "attest",
               attest_call({:session, "holder"}, child_assignment.id, "completion")
             )

    root =
      case terminal_notices(ctx.db) do
        [notice] -> notice
        other -> flunk("expected one root finish notice, got #{inspect(other)}")
      end

    assert root.prompt =~ "source_token=\"#{source_token}\""
    {parent_assignment, child_assignment, root}
  end

  defp action_note(child_assignment_id, root, action, detail) do
    [source_kind, source_token] = terminal_source(root.prompt)

    "completion-handoff-action #{child_assignment_id} #{source_kind} #{source_token} #{action}: #{detail}"
  end

  defp terminal_source(prompt) do
    fields =
      prompt
      |> String.split("\n", trim: true)
      |> Enum.find(&String.starts_with?(&1, "source_kind="))

    source_kind =
      fields |> String.replace_prefix("source_kind=", "") |> JSON.decode!()

    token =
      prompt
      |> String.split("\n", trim: true)
      |> Enum.find(&String.starts_with?(&1, "source_token="))
      |> String.replace_prefix("source_token=", "")
      |> JSON.decode!()

    [source_kind, token]
  end

  defp reminders(db, root_id) do
    {:ok, rows} =
      DB.query(db, "SELECT wakeId FROM wakes WHERE obligationRef=?1 ORDER BY rowid", [
        "terminal-child-owner-action-reminder:" <> root_id
      ])

    Enum.map(rows, fn [wake_id] -> Wakes.get(db, wake_id) end)
  end

  defp pending_reminders(db, root_id),
    do: Enum.filter(reminders(db, root_id), &(&1.state == "pending"))

  # Observe the source owner's asynchronous follow-through without firing another pass.
  defp await_pending_reminders(db, root_id, attempts \\ 200) do
    case pending_reminders(db, root_id) do
      [] when attempts > 0 ->
        Process.sleep(10)
        await_pending_reminders(db, root_id, attempts - 1)

      reminders ->
        reminders
    end
  end

  defp terminal_notices(db) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT wakeId FROM wakes WHERE obligationRef LIKE 'terminal-child-owner-notification:%'"
      )

    Enum.map(rows, fn [wake_id] -> Wakes.get(db, wake_id) end)
  end

  defp set_due_now(db, wake_id) do
    {:ok, _} = DB.query(db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [wake_id])
    :ok
  end

  defp turn_count(db, wake_id) do
    {:ok, [[count]]} = DB.query(db, "SELECT count(*) FROM turns WHERE wakeId=?1", [wake_id])
    count
  end

  defp assert_delivered_carrier(db, source_wake_id) do
    assert [%{delivery_wake_id: carrier_id, batch_state: "delivered"}] =
             NoticeBatcher.source_refs(db, source_wake_id)

    assert Wakes.get(db, source_wake_id).state == "fired"
    assert Wakes.get(db, carrier_id).state == "fired"
    assert turn_count(db, source_wake_id) == 0
    assert turn_count(db, carrier_id) == 1
    carrier_id
  end

  defp finish_carrier_turn!(db, carrier_id) do
    assert {:ok, [[seq]]} =
             DB.query(
               db,
               "SELECT seq FROM turns WHERE wakeId=?1 AND sessionKey='notice-parent'",
               [
                 carrier_id
               ]
             )

    assert {:ok, turn} = Ledger.claim_next(db, "notice-parent", "completion-handoff-test")
    assert turn.seq == seq

    assert :ok =
             Ledger.finish(db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)
  end

  defp start_scheduler(db) do
    name = Tightbeam.WakeScheduler

    start_supervised!(
      Supervisor.child_spec(
        {Wakes, db: db, name: name, tick_ms: 60_000, deliver: &deliver_wake(db, &1)},
        id: name
      )
    )

    name
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

  defp create_work_item(ctx, title) do
    WorkItems.__handle__(
      ctx.db,
      "work-item-create",
      call("work-item-create", {:user, "flynn"}, nil, %{title: title})
    )
  end

  defp handle(ctx, verb, call) when verb in ["assign", "attest"] do
    routed = %{call | verb: verb}

    routed =
      if verb == "assign", do: Map.put_new(routed, :supervision_interval_ms, 1_000), else: routed

    Assignments.__handle__(ctx.db, verb, routed)
  end

  defp handle(ctx, verb, call), do: WorkItems.__handle__(ctx.db, verb, %{call | verb: verb})

  defp assign_call(principal, target, subject, work_item_id, opts \\ []) do
    call("assign", principal, target, %{
      subject: subject,
      idempotency_key: nil,
      work_item_id: work_item_id,
      effect_kind: opts[:effect_kind]
    })
    |> Map.merge(%{target_role: nil, role_fallback: false})
  end

  defp attest_call(principal, assignment_id, kind) do
    call("attest", principal, nil, %{assignment_id: assignment_id, kind: kind})
  end

  defp progress_call(principal, assignment_id, note) do
    attest_call(principal, assignment_id, "progress")
    |> put_in([:params, :note], note)
  end

  defp call(verb, principal, target, params) do
    %{
      verb: verb,
      origin: origin(principal),
      principal: principal,
      session_key: target,
      params: params
    }
  end

  defp origin({:session, session_key}), do: "agent:#{session_key}"
  defp origin({:user, user_id}), do: "user:#{user_id}"

  defp session(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: if(key == Org.personal_session_key(owner), do: "main", else: "custom"),
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "lab1"
    })
  end
end
