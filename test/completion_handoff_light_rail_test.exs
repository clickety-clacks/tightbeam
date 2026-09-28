defmodule Tightbeam.CompletionHandoffLightRailTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Assignments, ConnRegistry, DB, Gateway, Model, Org, Rules, Wakes, WorkItems}

  defmodule LaneDoorbell do
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)

    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, _session_key}, _from, parent),
      do: {:reply, :ok, parent}
  end

  setup do
    db = :"completion_handoff_#{System.unique_integer([:positive])}"
    scheduler = :"completion_handoff_scheduler_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    register_hosts(db, %{
      "eezo" => %{
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
    Rules.load!(System.tmp_dir!(), Map.keys(handlers))

    start_supervised!(
      Supervisor.child_spec(
        {Wakes, db: db, name: scheduler, tick_ms: 60_000, deliver: &deliver_wake(db, &1)},
        id: scheduler
      )
    )

    %{db: db, scheduler: scheduler, handlers: handlers}
  end

  test "a delivered finish notice starts successive fallback reminders and survives restart",
       ctx do
    {parent_assignment, child_assignment, root} = completed_child(ctx)
    assert parent_assignment.state == "open"
    assert reminders(ctx.db, root.wake_id) == []

    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert Wakes.get(ctx.db, root.wake_id).state == "fired"

    assert {:ok, [[root_seq, "notice-parent"]]} =
             DB.query(ctx.db, "SELECT seq,sessionKey FROM turns WHERE wakeId=?1", [root.wake_id])

    [first] = pending_reminders(ctx.db, root.wake_id)
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
    assert [^first] = pending_reminders(ctx.db, root.wake_id)

    set_due_now(ctx.db, first.wake_id)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert Wakes.get(ctx.db, first.wake_id).state == "fired"
    assert turn_count(ctx.db, first.wake_id) == 1
    [second] = pending_reminders(ctx.db, root.wake_id)
    refute second.wake_id == first.wake_id

    stop_supervised!(ctx.scheduler)
    restarted = start_scheduler(ctx.db)
    assert :ok = Wakes.fire_due(restarted)
    assert Wakes.get(ctx.db, second.wake_id).state == "pending"

    set_due_now(ctx.db, second.wake_id)
    assert :ok = Wakes.fire_due(restarted)
    assert Wakes.get(ctx.db, second.wake_id).state == "fired"
    assert turn_count(ctx.db, first.wake_id) == 1
    assert turn_count(ctx.db, second.wake_id) == 1
    [third] = pending_reminders(ctx.db, root.wake_id)
    refute third.wake_id in [first.wake_id, second.wake_id]
  end

  test "a recovered finish notice without an action destination remains notice-only", ctx do
    item = create_work_item(ctx, "recovered completion")

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
    assert root.state == "canceled"
    assert reminders(ctx.db, root.wake_id) == []

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='active' WHERE sessionKey='notice-parent'")

    assert {:ok, {:ok, %{wake: recovered, replay: false}}} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.recover_terminal_notification_in_txn(
                 txn,
                 root.wake_id,
                 "session:notice-parent"
               )
             end)

    refute recovered.wake_id == root.wake_id
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert Wakes.get(ctx.db, recovered.wake_id).state == "fired"
    assert turn_count(ctx.db, recovered.wake_id) == 1
    assert reminders(ctx.db, recovered.wake_id) == []
  end

  test "a parent with no open assignment gets the initial notice but no reminder rail", ctx do
    {nil, child_assignment, root} = completed_child(ctx, with_parent_destination: false)

    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert Wakes.get(ctx.db, root.wake_id).state == "fired"
    assert turn_count(ctx.db, root.wake_id) == 1
    assert reminders(ctx.db, root.wake_id) == []

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

  test "a pending reminder is truthfully canceled if the parent's last open assignment closes",
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

    set_due_now(ctx.db, pending.wake_id)
    assert :ok = Wakes.fire_due(ctx.scheduler)

    assert Wakes.get(ctx.db, pending.wake_id).state == "canceled"
    assert turn_count(ctx.db, pending.wake_id) == 0
    assert pending_reminders(ctx.db, root.wake_id) == []

    assert {:ok, [["target_unresolvable", "scheduler_delivery", wake_id, "no_replacement"]]} =
             DB.query(
               ctx.db,
               "SELECT reasonKind,causalSourceKind,causalSourceId,outcomeKind FROM wake_cancellations WHERE wakeId=?1",
               [pending.wake_id]
             )

    assert wake_id == pending.wake_id
  end

  test "a delivered reminder does not rearm after the parent loses its last open assignment",
       ctx do
    {parent_assignment, _child_assignment, root} =
      completed_child(ctx, parent_opener: "other-parent")

    assert :ok = Wakes.fire_due(ctx.scheduler)
    [first] = pending_reminders(ctx.db, root.wake_id)
    set_due_now(ctx.db, first.wake_id)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert Wakes.get(ctx.db, first.wake_id).state == "fired"
    assert turn_count(ctx.db, first.wake_id) == 1
    [successor] = pending_reminders(ctx.db, root.wake_id)

    assert %{assignment: %{state: "closed"}} =
             handle(
               ctx,
               "attest",
               attest_call({:session, "notice-parent"}, parent_assignment.id, "completion")
             )

    set_due_now(ctx.db, successor.wake_id)
    assert :ok = Wakes.fire_due(ctx.scheduler)

    assert Wakes.get(ctx.db, successor.wake_id).state == "canceled"
    assert turn_count(ctx.db, successor.wake_id) == 0
    assert pending_reminders(ctx.db, root.wake_id) == []
    assert length(reminders(ctx.db, root.wake_id)) == 2
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

    assert packaged_manual =~ "copy `assignment_id`, `source_kind`, and `source_token`"

    assert packaged_manual =~
             "completion-handoff-action <assignment_id> <source_kind> <source_token> <kept|parked|retired> — <what you did>"

    assert packaged_manual =~ "preserve the literal em dash (`—`)"
    assert packaged_manual =~ "no reminder is scheduled and there is no lawful"
    assert packaged_manual =~ "do not self-assign or fabricate an acknowledgment"

    :initialized = Tightbeam.Identity.init!(base)
    revision = Tightbeam.Identity.live_revision!(base)

    for harness <- [:codex, :claude] do
      snapshot = Tightbeam.Identity.snapshot_at!(base, revision, "default", harness)
      assert snapshot.guidance =~ "copy `assignment_id`, `source_kind`, and `source_token`"

      assert snapshot.guidance =~
               "completion-handoff-action <assignment_id> <source_kind> <source_token> <kept|parked|retired> — <what you did>"

      assert snapshot.guidance =~ "preserve the literal em dash (`—`)"
      assert snapshot.guidance =~ "no reminder is scheduled and there is no lawful"
      assert snapshot.guidance =~ "do not self-assign or fabricate an acknowledgment"
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

  test "an action at the fallback boundary either stops the pending wake or cancels its successor",
       ctx do
    {parent_assignment, child_assignment, root} = completed_child(ctx)
    assert :ok = Wakes.fire_due(ctx.scheduler)
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
    [pending] = pending_reminders(ctx.db, root.wake_id)
    set_due_now(ctx.db, pending.wake_id)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    [successor] = pending_reminders(ctx.db, root.wake_id)
    assert turn_count(ctx.db, pending.wake_id) == 1

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

    "completion-handoff-action #{child_assignment_id} #{source_kind} #{source_token} #{action} — #{detail}"
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

  defp start_scheduler(db) do
    name = :"completion_handoff_scheduler_restart_#{System.unique_integer([:positive])}"

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
      {:terminal_notice_undeliverable, _} -> Gateway.complete_delivery(db, result)
      other -> other
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
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "eezo"
    })
  end
end
