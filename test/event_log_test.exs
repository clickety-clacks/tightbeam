defmodule Tightbeam.EventLogTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, EventLog}

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = EventLog.ensure_schema(name)
    %{db: name}
  end

  test "verb events append and tail in order; kind is constrained", %{db: db} do
    :ok = EventLog.append_event(db, "verb", "post", "user:flynn", "k1", %{a: 1})

    :ok =
      EventLog.append_event(
        db,
        "denied",
        "spawn",
        "agent:x",
        nil,
        %{rule: "cap"},
        {:session, "caller-key"}
      )

    [e1, e2] = EventLog.events_after(db, 0, 10)
    assert %{kind: "verb", verb: "post", session_key: "k1"} = e1

    assert %{kind: "denied", origin: "agent:x", principal: "session:caller-key", session_key: nil} =
             e2

    assert EventLog.events_after(db, e1.id, 10) == [e2]

    # the original events table keeps its verb|denied CHECK (additive-only rule)
    assert {:error, %Tightbeam.DB.Error{message: msg}} =
             DB.query(
               db,
               "INSERT INTO events (ts,kind,verb,origin) VALUES (1,'lifecycle','x','y')"
             )

    assert msg =~ "CHECK constraint"
  end

  test "an accepted event can share its caller transaction and exact clock", %{db: db} do
    assert {:ok, event_id} =
             DB.transaction(db, fn txn ->
               EventLog.append_event_in_txn(
                 txn,
                 "verb",
                 "wake",
                 "user:mike",
                 nil,
                 %{cancel_wake_id: "w_public", canceled: true},
                 {:user, "mike"},
                 12_345
               )
             end)

    assert is_integer(event_id) and event_id > 0

    assert {:ok, [[^event_id, 12_345, "verb", "wake", "user:mike", "user:mike", nil, payload]]} =
             DB.query(
               db,
               "SELECT id,ts,kind,verb,origin,principal,sessionKey,payload FROM events"
             )

    assert payload == "%{cancel_wake_id: \"w_public\", canceled: true}"

    assert {:error, %RuntimeError{message: "forced rollback"}} =
             DB.transaction(db, fn txn ->
               EventLog.append_event_in_txn(
                 txn,
                 "verb",
                 "wake",
                 "user:mike",
                 nil,
                 %{cancel_wake_id: "w_rolled_back", canceled: true},
                 {:user, "mike"},
                 12_346
               )

               raise "forced rollback"
             end)

    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM events")
  end

  test "boot epochs: clean shutdown leaves no dirty-exit; missing stamp infers one", %{db: db} do
    e1 = EventLog.boot(db)
    :ok = EventLog.clean_shutdown(db, e1)
    _e2 = EventLog.boot(db)
    assert EventLog.lifecycle_events(db) == []

    # e2 never stamped -> next boot infers dirty exit for it
    e3 = EventLog.boot(db)
    assert [%{kind: "dirty_exit", subject: subject}] = EventLog.lifecycle_events(db)
    assert subject == "epoch:#{e3 - 1}"
  end

  test "lifecycle records are free-form kinds on their own table", %{db: db} do
    :ok = EventLog.lifecycle(db, "adapter_restart", "claude:default", "backoff=2s gen=3")
    assert [%{kind: "adapter_restart", subject: "claude:default"}] = EventLog.lifecycle_events(db)
  end
end
