defmodule Tightbeam.ProcessAssignmentEventsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Assignments, DB, Schema}

  test "process provenance keeps the original owner and latest revoker across event history" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)

    insert(db, "verb", "assign", "session:worker", "%{id: legacy}")
    insert(db, "verb", "wake", "process:external", "unrelated legacy payload")
    insert(db, "verb", "assign", "process:tightbeam", "internal legacy payload")
    insert(db, "denied", "assign", "process:external", "denied legacy payload")

    event(db, "dispatch", "process:creator", "assignment-a", "original-owner")
    event(db, "assign", "process:other", "assignment-b", "other-owner")
    event(db, "assign", "process:retry", "assignment-a", "retry-owner")
    event(db, "revoke-assignment", "process:first-revoker", "assignment-a", nil)
    event(db, "revoke-assignment", "process:last-revoker", "assignment-a", nil)
    event(db, "revoke-assignment", "process:unrelated", "assignment-b", nil)

    assert {:ok, %{"principal" => "process:creator", "ownerUserId" => "original-owner"}} =
             DB.transaction(db, &Assignments.process_event_in_txn(&1, "assignment-a"))

    assert {:ok, %{"principal" => "process:last-revoker"}} =
             DB.transaction(
               db,
               &Assignments.process_event_in_txn(&1, "assignment-a", "revoke-assignment")
             )

    assert {:ok, nil} =
             DB.transaction(db, &Assignments.process_event_in_txn(&1, "missing-assignment"))

    # A repeated boot retains the index and the original provenance.
    :ok = Schema.ensure_all(db)

    assert {:ok, %{"principal" => "process:creator", "ownerUserId" => "original-owner"}} =
             DB.transaction(db, &Assignments.process_event_in_txn(&1, "assignment-a"))
  end

  defp event(db, verb, principal, id, owner) do
    insert(db, "verb", verb, principal, JSON.encode!(%{id: id, ownerUserId: owner}))
  end

  defp insert(db, kind, verb, principal, payload) do
    assert {:ok, []} =
             DB.query(
               db,
               "INSERT INTO events(ts,kind,verb,origin,principal,payload) VALUES(1,?1,?2,?3,?3,?4)",
               [kind, verb, principal, payload]
             )
  end
end
