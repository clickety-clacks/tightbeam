import ExUnit.Assertions
import ExUnit.CaptureLog
alias Tightbeam.{DB, Gateway, Model, Org, WorkItems}
ExUnit.start(autorun: false)

Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: config} ->
  Org.create(db, %{
    session_key: "k1",
    display_name: "k1",
    owner_user_id: "flynn",
    origin: "user:flynn",
    archetype: "default",
    host: "testhost",
    harness: "claude",
    provider: "anthropic",
    model: Model.new("fable")
  })

  create_work_item = fn title ->
    WorkItems.__handle__(db, "work-item-create", %{
      verb: "work-item-create",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{title: title}
    })
  end

  first_item = create_work_item.("Audit reviewed")
  second_item = create_work_item.("Audit conflict")

  :ok =
    DB.execute(
      db,
      """
      INSERT INTO assignments
        (id, subject, holderKey, openedByUser, openedAt, workItemId)
      VALUES
        ('asg_audit_target', 'target', 'k1', 'flynn', 1, '#{first_item.id}'),
        ('asg_audit_conflict', 'conflict', 'k1', 'flynn', 2, '#{second_item.id}');
      UPDATE assignments
      SET reviewsAssignmentId = 'asg_audit_target'
      WHERE id = 'asg_audit_conflict';

      INSERT INTO assignments
        (id, subject, holderKey, openedByUser, openedAt)
      VALUES
        ('asg_cycle_a', 'cycle a', 'k1', 'flynn', 3),
        ('asg_cycle_b', 'cycle b', 'k1', 'flynn', 4);
      UPDATE assignments SET reviewsAssignmentId = 'asg_cycle_b' WHERE id = 'asg_cycle_a';
      UPDATE assignments SET reviewsAssignmentId = 'asg_cycle_a' WHERE id = 'asg_cycle_b';
      """
    )

  {:ok, before_rows} =
    DB.query(
      db,
      """
      SELECT id, workItemId, reviewsAssignmentId
      FROM assignments
      WHERE id LIKE 'asg_audit_%' OR id LIKE 'asg_cycle_%'
      ORDER BY id
      """
    )

  log =
    capture_log(fn ->
      Gateway.children(%{config | port: 0})
    end)

  assert log =~ "review_item_conflict legacy assignment=asg_audit_conflict"
  assert log =~ "workItemId=#{second_item.id}"
  assert log =~ "reviewedWorkItemId=#{inspect(first_item.id)}"

  assert {:ok, ^before_rows} =
           DB.query(
             db,
             """
             SELECT id, workItemId, reviewsAssignmentId
             FROM assignments
             WHERE id LIKE 'asg_audit_%' OR id LIKE 'asg_cycle_%'
             ORDER BY id
             """
           )
end)

IO.puts("guarded-gateway-audit: ok")
