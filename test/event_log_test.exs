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

  test "pre-existing events table gains the principal column" do
    db = :"old_events_db_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({DB, path: ":memory:", name: db}, id: db))

    :ok =
      DB.execute(db, """
      CREATE TABLE events (
        id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('verb','denied')), verb TEXT NOT NULL,
        origin TEXT NOT NULL, sessionKey TEXT, payload TEXT NOT NULL DEFAULT 'null'
      )
      """)

    assert :ok = EventLog.ensure_schema(db)
    {:ok, columns} = DB.query(db, "PRAGMA table_info(events)")
    assert Enum.any?(columns, fn [_cid, name | _] -> name == "principal" end)
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
