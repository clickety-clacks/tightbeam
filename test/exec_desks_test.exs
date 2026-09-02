defmodule Tightbeam.ExecDesksTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, ExecDesks, Model, Org, Wakes}

  setup do
    db = :"exec_desks_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    worker =
      Org.create(db, %{
        session_key: "worker",
        display_name: "Worker",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "fixture",
        provider: "fixture_provider",
        model: Model.new("fixture"),
        kind: "main",
        is_built_in: true,
        adopted: true
      })

    %{db: db, worker: worker}
  end

  test "is off by default and a binding must elect enablement", %{db: db, worker: worker} do
    assert {:ok, false} = DB.transaction(db, &ExecDesks.enabled_in_txn?(&1, worker.session_key))

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               ExecDesks.bind_in_txn(txn, worker.session_key, "exec_one", true, 1)
             end)

    assert {:ok, true} = DB.transaction(db, &ExecDesks.enabled_in_txn?(&1, worker.session_key))
  end

  test "timing and grouping preserve the now-or-next and N-greater-than-one boundaries" do
    assert ExecDesks.timing("fyi", "agent:coder") == :next
    assert ExecDesks.timing("status-query", "user:flynn") == :next
    assert ExecDesks.timing("blocker", "agent:coder") == :now
    assert ExecDesks.timing(nil, "agent:coder") == :now
    assert {:direct, %{wake_id: "w1"}} = ExecDesks.group([%{wake_id: "w1"}])

    assert {:bundle, [%{wake_id: "w1"}, %{wake_id: "w2"}]} =
             ExecDesks.group([%{wake_id: "w1"}, %{wake_id: "w2"}])
  end

  test "ringdown uses only onboarded candidates in declared order" do
    candidates = [
      %{provider: :first, onboarded?: false},
      %{provider: :second, onboarded?: true},
      %{provider: :third, onboarded?: true}
    ]

    assert {:ok, :answer, %{provider: :second}} =
             ExecDesks.ringdown(candidates, fn %{provider: provider} ->
               if provider == :second, do: {:ok, :answer}, else: {:error, :unused}
             end)
  end

  test "an enabled exec writes an ordered BUNDLE and preserves source wakes", %{
    db: db,
    worker: worker
  } do
    w1 =
      Wakes.schedule(db, %{
        session_key: worker.session_key,
        origin: "agent:one",
        prompt: "one",
        due_at: 1
      })

    w2 =
      Wakes.schedule(db, %{
        session_key: worker.session_key,
        origin: "agent:two",
        prompt: "two",
        due_at: 1
      })

    assert {:ok, bundle_id} =
             DB.transaction(db, fn txn ->
               :ok = ExecDesks.bind_in_txn(txn, worker.session_key, "exec_one", true, 1)
               ExecDesks.open_bundle_in_txn(txn, worker.session_key, [w1.wake_id, w2.wake_id], 2)
             end)

    wake_one = w1.wake_id
    wake_two = w2.wake_id

    assert {:ok, [[^wake_one, 1], [^wake_two, 2]]} =
             DB.query(
               db,
               "SELECT wakeId, ordinal FROM exec_desk_bundle_members WHERE bundleId=?1 ORDER BY ordinal",
               [bundle_id]
             )

    assert {:ok, :ok} =
             DB.transaction(
               db,
               &ExecDesks.terminalize_bundle_in_txn(&1, bundle_id, :delivered, nil, 3)
             )

    assert {:ok, [["pending"], ["pending"]]} =
             DB.query(db, "SELECT state FROM wakes WHERE wakeId IN (?1, ?2) ORDER BY wakeId", [
               w1.wake_id,
               w2.wake_id
             ])
  end

  test "BUNDLE delivery and its terminal outcome commit together", %{db: db, worker: worker} do
    w1 =
      Wakes.schedule(db, %{
        session_key: worker.session_key,
        origin: "agent:one",
        prompt: "one",
        due_at: 1
      })

    w2 =
      Wakes.schedule(db, %{
        session_key: worker.session_key,
        origin: "agent:two",
        prompt: "two",
        due_at: 1
      })

    assert {:ok, {:appended, _worker, _message, _opts}} =
             DB.transaction(db, fn txn ->
               :ok = ExecDesks.bind_in_txn(txn, worker.session_key, "exec_one", true, 1)

               bundle_id =
                 ExecDesks.open_bundle_in_txn(
                   txn,
                   worker.session_key,
                   [w1.wake_id, w2.wake_id],
                   2
                 )

               ExecDesks.deliver_bundle_in_txn(
                 txn,
                 bundle_id,
                 worker.session_key,
                 "agent:exec",
                 "bundle",
                 3
               )
             end)

    assert {:ok, [["delivered", 3]]} =
             DB.query(db, "SELECT state, terminalAt FROM exec_desk_bundles")

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT COUNT(*) FROM turns WHERE sessionKey=?1", [worker.session_key])
  end

  test "annotations cite a durable row and parent escalation uses the effective-parent resolver",
       %{
         db: db,
         worker: worker
       } do
    child =
      Org.create(db, %{
        session_key: "child",
        display_name: "Child",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "fixture",
        provider: "fixture_provider",
        model: Model.new("fixture"),
        operational_parent: worker.session_key
      })

    wake =
      Wakes.schedule(db, %{
        session_key: worker.session_key,
        origin: "agent:one",
        prompt: "one",
        due_at: 1
      })

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               :ok = ExecDesks.bind_in_txn(txn, worker.session_key, "exec_one", true, 1)

               assert ExecDesks.effective_parent_in_txn(txn, child.session_key) ==
                        worker.session_key

               ExecDesks.annotate_in_txn(
                 txn,
                 %{wake_id: wake.wake_id},
                 worker.session_key,
                 "exec_one",
                 "assignment",
                 "asg_closed",
                 2
               )
             end)

    worker_key = worker.session_key

    assert {:ok, [[^worker_key, "exec_one", "assignment", "asg_closed"]]} =
             DB.query(
               db,
               "SELECT workerSessionKey, execId, citedKind, citedId FROM exec_desk_annotations"
             )
  end

  test "failed delivery leaves the BUNDLE open for replay", %{db: db, worker: worker} do
    w1 =
      Wakes.schedule(db, %{
        session_key: worker.session_key,
        origin: "agent:one",
        prompt: "one",
        due_at: 1
      })

    w2 =
      Wakes.schedule(db, %{
        session_key: worker.session_key,
        origin: "agent:two",
        prompt: "two",
        due_at: 1
      })

    assert {:ok, :invalid_reply_reference} =
             DB.transaction(db, fn txn ->
               :ok = ExecDesks.bind_in_txn(txn, worker.session_key, "exec_one", true, 1)

               bundle_id =
                 ExecDesks.open_bundle_in_txn(
                   txn,
                   worker.session_key,
                   [w1.wake_id, w2.wake_id],
                   2
                 )

               ExecDesks.deliver_bundle_in_txn(
                 txn,
                 bundle_id,
                 worker.session_key,
                 "agent:exec",
                 "bundle",
                 3,
                 reply_to_llm_visible_message_id: "missing"
               )
             end)

    assert {:ok, [["open"]]} = DB.query(db, "SELECT state FROM exec_desk_bundles")
  end
end
