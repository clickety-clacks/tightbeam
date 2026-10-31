import ExUnit.Assertions
alias Tightbeam.{DB, Gateway, Identity, Model, Org, Rules, Supervision, Wakes}

Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: config, base: base} ->
  Identity.init!(base)

  Org.create(db, %{
    session_key: "k1",
    display_name: "Main",
    owner_user_id: "flynn",
    origin: "user:flynn",
    archetype: "default",
    host: "testhost",
    harness: "claude",
    provider: "anthropic",
    model: Model.new("fable")
  })

  rules_dir = Path.join([base, "identity", "rules"])
  File.mkdir_p!(rules_dir)

  source =
    Path.join(
      :code.priv_dir(:tightbeam),
      "kungfu/agentic-engineering/rules/row-reaction-assignment-inactivity.toml"
    )

  valid = File.read!(source)
  policy_path = Path.join(rules_dir, "row-reaction-assignment-inactivity.toml")
  File.write!(policy_path, valid)
  assert [] = Gateway.load_law!(config)

  opened_at = System.system_time(:millisecond) - 3_600_000

  {:ok, _} =
    DB.query(
      db,
      "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt,state) " <>
        "VALUES ('asg_startup_r06','startup reaction','k1','flynn',?1,'open')",
      [opened_at]
    )

  assert {:ok, :ok} =
           DB.transaction(db, fn txn ->
             Supervision.assignment_opened_in_txn(txn, "asg_startup_r06", opened_at, 1_800_000)
           end)

  assert {:ok, [[deadline_id]]} =
           DB.query(
             db,
             "SELECT wakeId FROM wakes WHERE assignmentId='asg_startup_r06' AND consumer='assignment_inactivity_deadline' AND state='pending'"
           )

  deadline = Wakes.get(db, deadline_id)

  assert deadline.due_at < System.system_time(:millisecond)
  assert {:ok, :ok} = Supervision.deadline(db, deadline)

  assert {:ok, [[notice_id]]} =
           DB.query(
             db,
             "SELECT wakeId FROM wakes WHERE assignmentId='asg_startup_r06' AND consumer='prompt' AND obligationRef LIKE 'assignment-inactivity-episode-v1:%' AND state='pending'"
           )

  notice = Wakes.get(db, notice_id)

  assert {:ok, [[climb_id]]} =
           DB.query(
             db,
             "SELECT wakeId FROM wakes WHERE assignmentId='asg_startup_r06' AND consumer='assignment_inactivity_climb' AND state='pending'"
           )

  climb = Wakes.get(db, climb_id)

  assert is_map(notice)
  assert is_map(climb)

  {:ok, _} =
    DB.query(
      db,
      "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt,state) " <>
        "VALUES ('asg_startup_r06_deadline','startup deadline','k1','flynn',?1,'open')",
      [opened_at]
    )

  assert {:ok, :ok} =
           DB.transaction(db, fn txn ->
             Supervision.assignment_opened_in_txn(
               txn,
               "asg_startup_r06_deadline",
               opened_at,
               1_800_000
             )
           end)

  assert {:ok, [[deadline_to_cancel_id]]} =
           DB.query(
             db,
             "SELECT wakeId FROM wakes WHERE assignmentId='asg_startup_r06_deadline' AND consumer='assignment_inactivity_deadline' AND state='pending'"
           )

  deadline_to_cancel = Wakes.get(db, deadline_to_cancel_id)

  File.write!(
    policy_path,
    String.replace(valid, "period_ms = 1800000", "period_ms = 0", global: false)
  )

  _children = Gateway.children(config)

  assert %{settings: %{"period_ms" => 0}} = Rules.reaction_policy("assignment-inactivity")
  assert Wakes.get(db, deadline_to_cancel.wake_id).state == "canceled"
  assert Wakes.get(db, climb.wake_id).state == "canceled"
  assert Wakes.get(db, notice.wake_id).state == "canceled"
end)

IO.puts("invalid-assignment-inactivity-startup: ok")
