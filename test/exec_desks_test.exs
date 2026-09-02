defmodule Tightbeam.ExecDesksTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, ExecDesks, Model, Org}

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
end
