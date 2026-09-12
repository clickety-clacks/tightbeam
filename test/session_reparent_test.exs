defmodule Tightbeam.SessionReparentTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Gateway, Ledger, Model, Org, Roles, Schema, SessionReparent, Supervision, WorkItems}
  alias Tightbeam.DB.Txn

  # Synthetic local database fixtures: no provider, credential or harness behavior is simulated.
  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',0,1),('other',1,1)")
    parent = Org.personal_session_key("owner")
    session(db, parent, %{kind: "main", is_built_in: true})
    session(db, "child")
    session(db, "old")
    session(db, "foreign", %{owner_user_id: "other"})
    item(db, "wi_one")
    assignment(db, "asg_one", "child", "wi_one")
    %{db: db, parent: parent, params: %{session_key: "child", parent_session_key: parent,
      assignment_id: "asg_one", idempotency_key: "correct-one"}}
  end

  test "owner correction is append-only, replayable, and separates origin from current reads", ctx do
    db = ctx.db
    Roles.create!(db, "worker:synthetic", "owner", "child")
    origin = rows(db, "SELECT * FROM sessions ORDER BY sessionKey")
    assignment = rows(db, "SELECT * FROM assignments")
    before_tree = tree(db)
    before_role = Roles.resolve(db, "worker:synthetic")
    handlers = Gateway.handlers(%{db: db})
    result = handlers["session-reparent"].(call(ctx.params))
    assert result["session"] == %{"sessionKey" => "child", "originParent" => nil,
      "previousCurrentParent" => nil, "currentParent" => ctx.parent}
    assert result["assignment"]["originOpenerRef"] == "user:owner"
    assert result["assignment"]["currentCoordinationParentRef"] == "session:" <> ctx.parent
    assert Org.get(db, "child").spawned_by == nil
    assert Org.get(db, "child").current_parent == ctx.parent
    assert rows(db, "SELECT * FROM sessions ORDER BY sessionKey") == origin
    assert rows(db, "SELECT * FROM assignments") == assignment
    assert Roles.resolve(db, "worker:synthetic") == before_role
    assert handlers["role-list"].(%{})[:roles] |> Enum.any?(&(&1.bound_session_current_parent == ctx.parent))

    trace = WorkItems.__handle__(db, "work-item-trace", %{call(%{}) | params: %{work_item_id: "wi_one"}})
    assert hd(trace.assignments).openerRef == "user:owner"
    assert hd(trace.assignments).currentCoordinationParentRef == "session:" <> ctx.parent
    assert Enum.any?(trace.timeline, &(&1.type == "session_reparent" and &1.id == result["eventId"]))
    after_tree = tree(db)
    assert hd(after_tree.items).parent == hd(before_tree.items).parent
    assert hd(after_tree.items).current_coordination == [%{assignment_id: "asg_one", holder_key: "child",
      current_coordination_parent_ref: "session:" <> ctx.parent}]

    assert SessionReparent.handle(db, call(ctx.params)) == result
    assert count(db, "session_reparent_events") == 1
    assert %{code: "idempotency_conflict"} = SessionReparent.handle(db, call(%{ctx.params | parent_session_key: "old"}))
    assert %{code: "no_change"} = SessionReparent.handle(db, call(%{ctx.params | idempotency_key: "another-key"}))
    assert count(db, "wire_idempotency") == 1
    assert {:error, _} = DB.query(db, "UPDATE session_reparent_events SET cause=cause")
    assert {:error, _} = DB.query(db, "DELETE FROM session_reparent_events")
  end

  test "only the owning user can correct an active custom child with one direct open assignment", ctx do
    for principal <- [{:session, "child"}, {:process, "synthetic"}] do
      assert %{code: "user_principal_required"} = SessionReparent.handle(ctx.db, %{call(ctx.params) | principal: principal})
    end
    assert %{code: "not_authorized"} = SessionReparent.handle(ctx.db, %{call(ctx.params) | principal: {:user, "other"}})
    for patch <- [%{parent_session_key: "foreign"}, %{session_key: "foreign"}, %{assignment_id: "absent"}] do
      assert %{code: "not_authorized"} = SessionReparent.handle(ctx.db, call(Map.merge(ctx.params, patch)))
    end
    assert %{code: "unsupported_session"} = SessionReparent.handle(ctx.db, call(%{ctx.params | session_key: ctx.parent}))
    for key <- [nil, "", "   ", String.duplicate("x", 201), 1] do
      assert %{code: "invalid_message"} = SessionReparent.handle(ctx.db, call(%{ctx.params | idempotency_key: key}))
    end
    assignment(ctx.db, "asg_two", "child", "wi_one")
    assert %{code: "multiple_open_assignments"} = SessionReparent.handle(ctx.db, call(ctx.params))
    assert count(ctx.db, "session_reparent_events") == 0
    assert count(ctx.db, "wire_idempotency") == 0
  end

  test "foreign and closed work items refuse even for a caller owning the session", ctx do
    {:ok, _} = DB.query(ctx.db, "UPDATE work_items SET ownerUserId='other' WHERE id='wi_one'")
    assert %{code: "not_authorized"} = SessionReparent.handle(ctx.db, call(ctx.params))
    {:ok, _} = DB.query(ctx.db, "UPDATE work_items SET ownerUserId='owner',state='closed' WHERE id='wi_one'")
    assert %{code: "not_authorized"} = SessionReparent.handle(ctx.db, call(ctx.params))
    assert count(ctx.db, "session_reparent_events") == 0
    assert count(ctx.db, "wire_idempotency") == 0
  end

  test "cycles use committed corrections as well as origin edges", ctx do
    session(ctx.db, "descendant", %{spawned_by: "child"})
    for parent <- ["child", "descendant"] do
      assert %{code: "cycle_detected"} = SessionReparent.handle(ctx.db, call(%{ctx.params | parent_session_key: parent}))
    end
    assignment(ctx.db, "asg_old", "old", "wi_one")
    result = SessionReparent.handle(ctx.db, call(%{ctx.params | session_key: "old", parent_session_key: "child", assignment_id: "asg_old"}))
    assert is_binary(result["eventId"])
    assert %{code: "cycle_detected"} = SessionReparent.handle(ctx.db, call(%{ctx.params | parent_session_key: "old", idempotency_key: "cycle"}))
    assert count(ctx.db, "session_reparent_events") == 1
  end

  test "faults before each write and before commit roll back the complete correction", ctx do
    for point <- [:event, :idempotency, :commit] do
      result = DB.transaction(ctx.db, fn txn ->
        observed = Txn.observe_queries(txn, fn {:sql_query, sql, _} ->
          if (point == :event and String.contains?(sql, "INSERT INTO session_reparent_events")) or
             (point == :idempotency and String.contains?(sql, "INSERT INTO wire_idempotency")),
            do: raise("synthetic write fault")
        end)
        response = SessionReparent.apply_in_txn(observed, "owner", ctx.params)
        if point == :commit, do: raise("synthetic precommit fault")
        response
      end)
      assert {:error, %RuntimeError{}} = result
      assert count(ctx.db, "session_reparent_events") == 0
      assert count(ctx.db, "wire_idempotency") == 0
      assert Org.current_parent(ctx.db, "child") == nil
      assert SessionReparent.current_coordination_parent(ctx.db, "asg_one") == nil
    end
  end

  test "a running turn and pre-addressed work survive correction and finish under the same session", ctx do
    {:ok, seq} = Ledger.enqueue(ctx.db, %{session_key: "child", message_id: "synthetic-message",
      origin: "user:owner", prompt: "synthetic", assignment_id: "asg_one", job_ref: "wi_one"})
    assert {:ok, turn} = Ledger.claim_next(ctx.db, "child", "synthetic-runner")
    assert turn.seq == seq
    before = snapshot(ctx.db)
    result = SessionReparent.handle(ctx.db, call(ctx.params))
    assert is_binary(result["eventId"])
    assert snapshot(ctx.db) == before
    assert Supervision.ladder_target(ctx.db, "child", 1) == ctx.parent
    assert :ok = Ledger.finish(ctx.db, seq, "delivered")
    assert rows(ctx.db, "SELECT sessionKey,status FROM turns WHERE seq=#{seq}") == [["child", "delivered"]]
  end

  test "latest event wins, older retry remains canonical, and restart preserves both", ctx do
    first = SessionReparent.handle(ctx.db, call(ctx.params))
    second = SessionReparent.handle(ctx.db, call(%{ctx.params | parent_session_key: "old", idempotency_key: "second"}))
    assert second["session"]["previousCurrentParent"] == ctx.parent
    assert Org.current_parent(ctx.db, "child") == "old"
    assert SessionReparent.handle(ctx.db, call(ctx.params)) == first
    assert Org.current_parent(ctx.db, "child") == "old"
    assert :ok = Schema.ensure_all(ctx.db)
    assert Org.current_parent(ctx.db, "child") == "old"
    assert count(ctx.db, "session_reparent_events") == 2
  end

  defp session(db, key, extra \\ %{}) do
    Org.create(db, Map.merge(%{session_key: key, display_name: key, owner_user_id: "owner",
      origin: "user:owner", archetype: "default", harness: "fixture", provider: "fixture",
      model: Model.new("fixture"), host: "synthetic-host"}, extra))
  end

  defp item(db, id) do
    {:ok, _} = DB.query(db, """
    INSERT INTO work_items(id,title,ownerUserId,state,createdByUser,createdContextKnown,createdAt)
    VALUES (?1,'synthetic item','owner','open','owner',0,1)
    """, [id])
  end

  defp assignment(db, id, holder, item) do
    {:ok, _} = DB.query(db, """
    INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,state,workItemId)
    VALUES (?1,'synthetic assignment',?2,'owner',1,'open',?3)
    """, [id,holder,item])
  end

  defp call(params), do: %{principal: {:user, "owner"}, origin: "user:owner", session_key: nil,
    verb: "session-reparent", params: params}
  defp rows(db, sql), do: elem(DB.query(db, sql), 1)
  defp count(db, table), do: rows(db, "SELECT COUNT(*) FROM #{table}") |> hd() |> hd()
  defp tree(db), do: Tightbeam.ExecutionMap.toplines(db, %{call(%{}) | params: %{state: "all"}})
  defp snapshot(db) do
    for table <- ~w(sessions assignments work_items turns messages wakes attests artifacts), into: %{},
      do: {table, rows(db, "SELECT * FROM #{table} ORDER BY rowid")}
  end
end
