defmodule Tightbeam.SessionReparentTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Assignments,
    DB,
    DeliveryResponsibilities,
    Gateway,
    Ledger,
    Model,
    Org,
    Roles,
    Schema,
    SessionReparent,
    SessionPoAssociations,
    Supervision,
    WorkItems
  }

  alias Tightbeam.DB.Txn

  # Synthetic local database fixtures: no provider, credential or harness behavior is simulated.
  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',0,1),('other',1,1)"
      )

    parent = Org.personal_session_key("owner")
    session(db, parent, %{kind: "main", is_built_in: true})
    session(db, "child")
    session(db, "old")
    session(db, "foreign", %{owner_user_id: "other"})
    item(db, "wi_one")
    assignment(db, "asg_one", "child", "wi_one")

    %{
      db: db,
      parent: parent,
      params: %{
        session_key: "child",
        parent_session_key: parent,
        assignment_id: "asg_one",
        idempotency_key: "correct-one"
      }
    }
  end

  test "owner correction is append-only, replayable, and separates origin from current reads",
       ctx do
    db = ctx.db
    Roles.create!(db, "worker:synthetic", "owner", "child")
    assignment = rows(db, "SELECT * FROM assignments")

    assert {:ok, seq} =
             Ledger.enqueue(db, %{
               session_key: "child",
               message_id: "causal-turn",
               origin: "user:owner",
               prompt: "create nested work",
               assignment_id: "asg_one",
               job_ref: "wi_one"
             })

    item(db, "wi_nested")

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE work_items SET createdContextKnown=1,createdInTurnSeq=?1 WHERE id='wi_nested'",
               [seq]
             )

    origin = rows(db, "SELECT * FROM sessions ORDER BY sessionKey")

    updated_at_index =
      rows(db, "PRAGMA table_info(sessions)")
      |> Enum.find_index(fn [_cid, name | _] -> name == "updatedAt" end)

    before_version = Org.get(db, "child").updated_at
    before_tree = tree(db)
    before_role = Roles.resolve(db, "worker:synthetic")
    handlers = Gateway.handlers(%{db: db})
    result = handlers["session-reparent"].(call(ctx.params))

    assert result["session"] == %{
             "sessionKey" => "child",
             "originParent" => nil,
             "previousCurrentParent" => nil,
             "currentParent" => ctx.parent
           }

    assert result["assignment"]["originOpenerRef"] == "user:owner"
    assert result["assignment"]["currentCoordinationParentRef"] == "session:" <> ctx.parent
    assert Org.get(db, "child").spawned_by == nil
    assert Org.get(db, "child").current_parent == ctx.parent
    assert Org.topology_parent(db, "child") == ctx.parent
    assert Org.get(db, "child").topology_parent == ctx.parent

    assert db
           |> Tightbeam.StateResources.query_session("child")
           |> Tightbeam.StateResources.session()
           |> Map.fetch!("topologyParent") == ctx.parent

    corrected = Org.get(db, "child")
    assert corrected.updated_at > before_version

    expected =
      Enum.map(origin, fn row ->
        if hd(row) == "child",
          do: List.replace_at(row, updated_at_index, corrected.updated_at),
          else: row
      end)

    assert rows(db, "SELECT * FROM sessions ORDER BY sessionKey") == expected
    assert rows(db, "SELECT * FROM assignments") == assignment
    assert Roles.resolve(db, "worker:synthetic") == before_role

    assert handlers["role-list"].(%{})[:roles]
           |> Enum.any?(&(&1.bound_session_current_parent == ctx.parent))

    trace =
      WorkItems.__handle__(db, "work-item-trace", %{call(%{}) | params: %{work_item_id: "wi_one"}})

    assert hd(trace.assignments).openerRef == "user:owner"
    assert hd(trace.assignments).currentCoordinationParentRef == "session:" <> ctx.parent

    assert Enum.any?(
             trace.timeline,
             &(&1.type == "session_reparent" and &1.id == result["eventId"])
           )

    after_tree = tree(db)
    assert hd(after_tree.roots).parent == hd(before_tree.roots).parent
    assert hd(hd(before_tree.roots).children).id == "wi_nested"
    assert hd(hd(after_tree.roots).children).id == "wi_nested"
    assert hd(hd(after_tree.roots).children).parent == hd(hd(before_tree.roots).children).parent

    assert hd(after_tree.roots).current_coordination == [
             %{
               assignment_id: "asg_one",
               holder_key: "child",
               current_coordination_parent_ref: "session:" <> ctx.parent
             }
           ]

    assert SessionReparent.handle(db, call(ctx.params)) == result
    assert count(db, "session_reparent_events") == 1

    assert %{code: "idempotency_conflict"} =
             SessionReparent.handle(db, call(%{ctx.params | parent_session_key: "old"}))

    assert %{code: "no_change"} =
             SessionReparent.handle(db, call(%{ctx.params | idempotency_key: "another-key"}))

    assert count(db, "wire_idempotency") == 1
    assert {:error, _} = DB.query(db, "UPDATE session_reparent_events SET cause=cause")
    assert {:error, _} = DB.query(db, "DELETE FROM session_reparent_events")
  end

  test "only the owning user can correct an active custom child with one direct open assignment",
       ctx do
    assert %{code: "delivery_responsibility_required"} =
             SessionReparent.handle(ctx.db, agent_call("child", ctx.params))

    assert %{code: "user_principal_required"} =
             SessionReparent.handle(ctx.db, %{
               call(ctx.params)
               | principal: {:process, "synthetic"}
             })

    assert %{code: "not_authorized"} =
             SessionReparent.handle(ctx.db, %{call(ctx.params) | principal: {:user, "other"}})

    for patch <- [
          %{parent_session_key: "foreign"},
          %{session_key: "foreign"},
          %{assignment_id: "absent"}
        ] do
      assert %{code: "not_authorized"} =
               SessionReparent.handle(ctx.db, call(Map.merge(ctx.params, patch)))
    end

    assert %{code: "unsupported_session"} =
             SessionReparent.handle(ctx.db, call(%{ctx.params | session_key: ctx.parent}))

    for key <- [nil, "", "   ", String.duplicate("x", 201), 1] do
      assert %{code: "invalid_message"} =
               SessionReparent.handle(ctx.db, call(%{ctx.params | idempotency_key: key}))
    end

    assignment(ctx.db, "asg_two", "child", "wi_one")
    assert %{code: "multiple_open_assignments"} = SessionReparent.handle(ctx.db, call(ctx.params))
    assert count(ctx.db, "session_reparent_events") == 0
    assert count(ctx.db, "wire_idempotency") == 0
  end

  test "accountable delivery owner moves only its current worker under its current coordinator",
       ctx do
    accountable_fixture(ctx)

    result = SessionReparent.handle(ctx.db, agent_call("lead", agent_params(ctx)))
    assert is_binary(result["eventId"])
    assert result["session"]["originParent"] == "lead"
    assert result["assignment"]["originOpenerRef"] == "session:lead"
    assert Org.current_parent(ctx.db, "child") == "coordinator"
    assert SessionReparent.current_coordination_parent(ctx.db, "asg_one") == "coordinator"
    assert Supervision.ladder_target(ctx.db, "child", 1) == "coordinator"

    assert rows(ctx.db, "SELECT principalKind,principalRef,cause FROM session_reparent_events") ==
             [
               ["session", "session:lead", "delivery_owner_reparent"]
             ]

    assert SessionReparent.handle(ctx.db, agent_call("lead", agent_params(ctx))) == result
    assert count(ctx.db, "session_reparent_events") == 1

    assert %{code: "idempotency_conflict"} =
             SessionReparent.handle(ctx.db, call(agent_params(ctx)))

    assert %{code: "idempotency_conflict"} =
             SessionReparent.handle(ctx.db, agent_call("coordinator", agent_params(ctx)))

    assert %{code: "current_custody_required", message: message} =
             SessionReparent.handle(
               ctx.db,
               agent_call("lead", %{agent_params(ctx) | idempotency_key: "after-transfer"})
             )

    assert message =~ "owning user"
    assert count(ctx.db, "session_reparent_events") == 1
  end

  test "valid delegated owner may move its worker and a recorded successor uses current custody",
       ctx do
    accountable_fixture(ctx)
    delegated_lane(ctx.db)
    assert DeliveryResponsibilities.responsibility(ctx.db, "lane", "wi_one") == "delegated"

    # The operator makes a durable custody correction. Historical spawnedBy and
    # openedBySession still name lead, while both current custody reads name lane.
    assert is_binary(
             SessionReparent.handle(
               ctx.db,
               call(%{agent_params(ctx) | parent_session_key: "lane", idempotency_key: "to-lane"})
             )["eventId"]
           )

    assert Org.get(ctx.db, "child").spawned_by == "lead"

    assert rows(ctx.db, "SELECT openedBySession FROM assignments WHERE id='asg_one'") == [
             ["lead"]
           ]

    result =
      SessionReparent.handle(
        ctx.db,
        agent_call("lane", %{
          agent_params(ctx)
          | parent_session_key: "lane-coordinator",
            idempotency_key: "lane-move"
        })
      )

    assert is_binary(result["eventId"])
    assert result["assignment"]["originOpenerRef"] == "session:lead"
    assert result["assignment"]["previousCurrentCoordinationParentRef"] == "session:lane"

    assert rows(ctx.db, "SELECT principalRef FROM session_reparent_events ORDER BY eventSeq") == [
             ["user:owner"],
             ["session:lane"]
           ]
  end

  test "agent authority requires exact current responsibility and both current custody facts",
       ctx do
    accountable_fixture(ctx)
    delegated_lane(ctx.db)
    session(ctx.db, "outsider")

    assert %{code: "delivery_responsibility_required"} =
             SessionReparent.handle(ctx.db, agent_call("outsider", agent_params(ctx)))

    assert %{code: "current_custody_required"} =
             SessionReparent.handle(ctx.db, agent_call("lane", agent_params(ctx)))

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE assignments SET openedBySession=NULL,openedByUser='owner' WHERE id='asg_one'"
             )

    assert %{code: "current_custody_required"} =
             SessionReparent.handle(ctx.db, agent_call("lead", agent_params(ctx)))

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE assignments SET openedBySession='outsider',openedByUser=NULL WHERE id='asg_one'"
             )

    assert %{code: "current_custody_required"} =
             SessionReparent.handle(ctx.db, agent_call("lead", agent_params(ctx)))

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET openedBySession='lead' WHERE id='asg_one'")

    assert is_binary(
             SessionReparent.handle(
               ctx.db,
               call(%{agent_params(ctx) | parent_session_key: "lane", idempotency_key: "handoff"})
             )["eventId"]
           )

    assert %{code: "current_custody_required"} =
             SessionReparent.handle(
               ctx.db,
               agent_call("lead", %{agent_params(ctx) | idempotency_key: "former-lead"})
             )

    assert count(ctx.db, "session_reparent_events") == 1
  end

  test "agent target must remain a direct active child, with one assignment and no cycle", ctx do
    accountable_fixture(ctx)
    session(ctx.db, "outsider")

    assert %{code: "not_authorized"} =
             SessionReparent.handle(
               ctx.db,
               agent_call("lead", %{agent_params(ctx) | parent_session_key: "foreign"})
             )

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE sessions SET spawnedBy='outsider' WHERE sessionKey='coordinator'"
             )

    assert %{code: "target_not_owned"} =
             SessionReparent.handle(ctx.db, agent_call("lead", agent_params(ctx)))

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE sessions SET spawnedBy='lead',state='retired' WHERE sessionKey='coordinator'"
             )

    assert %{code: "session_retired"} =
             SessionReparent.handle(ctx.db, agent_call("lead", agent_params(ctx)))

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE sessions SET state='active' WHERE sessionKey='coordinator'")

    assert %{code: "cycle_detected"} =
             SessionReparent.handle(
               ctx.db,
               agent_call("lead", %{agent_params(ctx) | parent_session_key: "child"})
             )

    assignment(ctx.db, "asg_two", "child", "wi_one")

    assert %{code: "multiple_open_assignments"} =
             SessionReparent.handle(ctx.db, agent_call("lead", agent_params(ctx)))

    assert count(ctx.db, "session_reparent_events") == 0
  end

  test "a target transferred by a later event is no longer owned by its original parent", ctx do
    accountable_fixture(ctx)
    session(ctx.db, "outsider")
    item(ctx.db, "wi_target")
    assignment(ctx.db, "asg_target", "coordinator", "wi_target")

    assert is_binary(
             SessionReparent.handle(
               ctx.db,
               call(%{
                 session_key: "coordinator",
                 parent_session_key: "outsider",
                 assignment_id: "asg_target",
                 idempotency_key: "transfer-target"
               })
             )["eventId"]
           )

    assert Org.get(ctx.db, "coordinator").spawned_by == "lead"
    assert Org.current_parent(ctx.db, "coordinator") == "outsider"

    assert %{code: "target_not_owned"} =
             SessionReparent.handle(ctx.db, agent_call("lead", agent_params(ctx)))

    assert count(ctx.db, "session_reparent_events") == 1
  end

  test "a same-human work item or stale office does not grant an agent delivery authority", ctx do
    accountable_fixture(ctx)
    item(ctx.db, "wi_unbound")

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET workItemId='wi_unbound' WHERE id='asg_one'")

    assert %{code: "delivery_responsibility_required"} =
             SessionReparent.handle(ctx.db, agent_call("lead", agent_params(ctx)))

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET workItemId='wi_one' WHERE id='asg_one'")

    Roles.create!(ctx.db, "product-owner:next", "owner", "lead")
    associate(ctx.db, "lead", "product-owner:next", "lead-association-next")
    assert DeliveryResponsibilities.responsibility(ctx.db, "lead", "wi_one") == "stale"

    assert %{code: "delivery_responsibility_required"} =
             SessionReparent.handle(ctx.db, agent_call("lead", agent_params(ctx)))

    assert count(ctx.db, "session_reparent_events") == 0
  end

  test "foreign and closed work items refuse even for a caller owning the session", ctx do
    {:ok, _} = DB.query(ctx.db, "UPDATE work_items SET ownerUserId='other' WHERE id='wi_one'")
    assert %{code: "not_authorized"} = SessionReparent.handle(ctx.db, call(ctx.params))

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE work_items SET ownerUserId='owner',state='closed' WHERE id='wi_one'"
      )

    assert %{code: "not_authorized"} = SessionReparent.handle(ctx.db, call(ctx.params))
    assert count(ctx.db, "session_reparent_events") == 0
    assert count(ctx.db, "wire_idempotency") == 0
  end

  test "cycles use committed corrections as well as origin edges", ctx do
    session(ctx.db, "descendant", %{spawned_by: "child"})

    for parent <- ["child", "descendant"] do
      assert %{code: "cycle_detected"} =
               SessionReparent.handle(ctx.db, call(%{ctx.params | parent_session_key: parent}))
    end

    assignment(ctx.db, "asg_old", "old", "wi_one")

    result =
      SessionReparent.handle(
        ctx.db,
        call(%{
          ctx.params
          | session_key: "old",
            parent_session_key: "child",
            assignment_id: "asg_old"
        })
      )

    assert is_binary(result["eventId"])

    assert %{code: "cycle_detected"} =
             SessionReparent.handle(
               ctx.db,
               call(%{ctx.params | parent_session_key: "old", idempotency_key: "cycle"})
             )

    assert count(ctx.db, "session_reparent_events") == 1
  end

  test "reparent publishes one committed version and replay or refusal publishes none", ctx do
    alias Tightbeam.Firehose.Hub
    start_supervised!({Hub, name: Hub})

    :ok =
      Hub.register(Hub, self(), %{
        mode: :subscribed,
        db: ctx.db,
        user_id: "owner",
        is_admin: false
      })

    :ok =
      Hub.subscribe(Hub, self(), "reparent", %{"classes" => ["session."], "sessionKey" => "child"})

    before = Org.get(ctx.db, "child")

    assert {:error, %RuntimeError{}} =
             DB.transaction(ctx.db, fn txn ->
               SessionReparent.apply_in_txn(txn, "owner", ctx.params)
               raise "synthetic rollback"
             end)

    assert Org.get(ctx.db, "child").updated_at == before.updated_at
    refute_receive {:firehose_notice, _}, 50

    result = SessionReparent.handle(ctx.db, call(ctx.params))
    assert_receive {:firehose_notice, %{"class" => "session.updated", "payload" => payload}}
    assert payload["rowVersion"] > before.updated_at
    assert payload == Tightbeam.StateResources.session(Org.get(ctx.db, "child"))
    assert SessionReparent.handle(ctx.db, call(ctx.params)) == result

    assert %{code: "no_change"} =
             SessionReparent.handle(ctx.db, call(%{ctx.params | idempotency_key: "duplicate"}))

    assert Org.get(ctx.db, "child").updated_at == payload["rowVersion"]
    refute_receive {:firehose_notice, _}, 50
  end

  test "faults before each write and before commit roll back the complete correction", ctx do
    for point <- [:event, :idempotency, :commit] do
      result =
        DB.transaction(ctx.db, fn txn ->
          observed =
            Txn.observe_queries(txn, fn {:sql_query, sql, _} ->
              if (point == :event and String.contains?(sql, "INSERT INTO session_reparent_events")) or
                   (point == :idempotency and
                      String.contains?(sql, "INSERT INTO wire_idempotency")),
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

  test "a running turn and pre-addressed work survive correction and finish under the same session",
       ctx do
    {:ok, seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: "child",
        message_id: "synthetic-message",
        origin: "user:owner",
        prompt: "synthetic",
        assignment_id: "asg_one",
        job_ref: "wi_one"
      })

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "child", "synthetic-runner")
    assert turn.seq == seq

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: "child",
               message_id: "queued-message",
               origin: "user:owner",
               prompt: "next existing turn",
               assignment_id: "asg_one",
               job_ref: "wi_one"
             })

    Org.append_pointer(ctx.db, "child", "synthetic-harness-pointer", "created")

    assert :ok =
             DB.execute(ctx.db, """
               INSERT INTO messages(id,sessionKey,role,content,timestamp,llmVisibleMessageId)
               VALUES ('history','child','user','existing transcript',1,'history');
             """)

    before = snapshot(ctx.db)
    before_version = Org.get(ctx.db, "child").updated_at

    updated_at_index =
      rows(ctx.db, "PRAGMA table_info(sessions)")
      |> Enum.find_index(fn [_cid, name | _] -> name == "updatedAt" end)

    result = SessionReparent.handle(ctx.db, call(ctx.params))
    assert is_binary(result["eventId"])

    corrected = Org.get(ctx.db, "child")
    assert corrected.updated_at > before_version

    expected_sessions =
      Enum.map(before["sessions"], fn row ->
        if hd(row) == "child",
          do: List.replace_at(row, updated_at_index, corrected.updated_at),
          else: row
      end)

    assert snapshot(ctx.db) == %{before | "sessions" => expected_sessions}
    assert Supervision.ladder_target(ctx.db, "child", 1) == ctx.parent
    assert :ok = Ledger.finish(ctx.db, seq, "delivered", nil, owner_lease: turn.owner_lease)

    assert rows(ctx.db, "SELECT sessionKey,status FROM turns WHERE seq=#{seq}") == [
             ["child", "delivered"]
           ]
  end

  test "latest event wins, older retry remains canonical, and repeated schema validation preserves both",
       ctx do
    first = SessionReparent.handle(ctx.db, call(ctx.params))

    second =
      SessionReparent.handle(
        ctx.db,
        call(%{ctx.params | parent_session_key: "old", idempotency_key: "second"})
      )

    assert second["session"]["previousCurrentParent"] == ctx.parent
    assert Org.current_parent(ctx.db, "child") == "old"
    assert Org.topology_parent(ctx.db, "child") == "old"
    assert Org.get(ctx.db, "child").spawned_by == nil
    assert SessionReparent.handle(ctx.db, call(ctx.params)) == first
    assert Org.current_parent(ctx.db, "child") == "old"
    assert Org.topology_parent(ctx.db, "child") == "old"
    assert :ok = Schema.ensure_all(ctx.db)
    assert Org.current_parent(ctx.db, "child") == "old"
    assert SessionReparent.handle(ctx.db, call(ctx.params)) == first
    assert count(ctx.db, "session_reparent_events") == 2
  end

  test "corrected ancestor admission agrees with the migrated trigger and preserves old waits",
       ctx do
    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE sessions SET spawnedBy='old' WHERE sessionKey='child'")

    for parent <- ["old", ctx.parent] do
      assert {:ok, _} =
               Ledger.enqueue(ctx.db, %{
                 session_key: parent,
                 message_id: "turn-" <> parent,
                 origin: "user:owner",
                 prompt: "synthetic parent activity"
               })

      assert {:ok, _} = Ledger.claim_next(ctx.db, parent, "fixture-runner")
    end

    input = %{
      session_key: "child",
      origin: "agent:old",
      prompt: "continue existing assignment",
      assignment_id: "asg_one",
      after_turn: true,
      registrant_session_key: "old",
      owner_user_id: "owner"
    }

    assert {:ok, old_wait} =
             DB.transaction(ctx.db, &Tightbeam.Wakes.register_wait_in_txn(&1, input))

    assert is_binary(old_wait.wake_id)
    before = rows(ctx.db, "SELECT * FROM wakes ORDER BY rowid")
    assert is_binary(SessionReparent.handle(ctx.db, call(ctx.params))["eventId"])
    assert rows(ctx.db, "SELECT * FROM wakes ORDER BY rowid") == before

    assert {:ok, {:error, %{code: "not_holder"}}} =
             DB.transaction(ctx.db, &Tightbeam.Wakes.register_wait_in_txn(&1, input))

    corrected = %{input | origin: "agent:" <> ctx.parent, registrant_session_key: ctx.parent}

    assert {:ok, new_wait} =
             DB.transaction(ctx.db, &Tightbeam.Wakes.register_wait_in_txn(&1, corrected))

    assert new_wait.creator_session_key == ctx.parent
    assert new_wait.session_key == "child"

    assert rows(
             ctx.db,
             "SELECT COUNT(*) FROM supervision_liveness_sidecar WHERE controllerOrigin='holder_continuation'"
           ) == [[2]]

    assert :ok = Schema.ensure_all(ctx.db)
  end

  @tag :tmp_dir
  test "guarded database reopen preserves correction and canonical retries", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(tmp, "session_reparent_restart.exs", "reparent-reopen: ok")
  end

  test "concurrent duplicate requests return one canonical event", ctx do
    tasks =
      for _ <- 1..2, do: Task.async(fn -> SessionReparent.handle(ctx.db, call(ctx.params)) end)

    [first, second] = Enum.map(tasks, &Task.await/1)
    assert is_binary(first["eventId"])
    assert first == second
    assert count(ctx.db, "session_reparent_events") == 1
    assert count(ctx.db, "wire_idempotency") == 1
  end

  test "populated historical schema migrates without losing legacy retries", _ctx do
    legacy = start_supervised!({DB, path: ":memory:", name: nil}, id: :legacy)
    assert :ok = DB.execute(legacy, File.read!(Path.join(__DIR__, "fixtures/r1_o2_v1.sql")))

    assert :ok =
             DB.execute(legacy, """
               INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt)
               VALUES ('legacy','legacy','owner','user:owner','default','fixture','fixture_provider','fixture',1,1);
               INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt) VALUES ('legacy-asg','legacy','legacy','owner',1);
               INSERT INTO wire_idempotency(ownerUserId,operation,idempotencyKey,sessionKey)
               VALUES ('owner','spawn','legacy-key','legacy');
             """)

    sessions = rows(legacy, "SELECT sessionKey,spawnedBy FROM sessions")
    assignments = rows(legacy, "SELECT id,openedByUser,openedBySession FROM assignments")
    assert :ok = Schema.ensure_all(legacy)
    assert rows(legacy, "SELECT sessionKey,spawnedBy FROM sessions") == sessions
    assert rows(legacy, "SELECT id,openedByUser,openedBySession FROM assignments") == assignments

    assert rows(
             legacy,
             "SELECT ownerUserId,operation,idempotencyKey,sessionKey FROM wire_idempotency"
           ) ==
             [["owner", "spawn", "legacy-key", "legacy"]]

    assert Org.current_parent(legacy, "legacy") == nil
    assert :ok = Schema.ensure_all(legacy)
  end

  defp accountable_fixture(ctx) do
    session(ctx.db, "lead")
    session(ctx.db, "coordinator", %{spawned_by: "lead"})

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE sessions SET spawnedBy='lead' WHERE sessionKey='child'")

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE assignments SET openedByUser=NULL,openedBySession='lead' WHERE id='asg_one'"
             )

    Roles.create!(ctx.db, "product-owner:reparent", "owner", "lead")
    associate(ctx.db, "lead", "product-owner:reparent", "lead-association")

    assert %{deliveryOwnerSessionKey: "lead"} =
             Tightbeam.WorkItems.__handle__(ctx.db, "work-item-update", %{
               verb: "work-item-update",
               origin: "user:owner",
               principal: {:user, "owner"},
               session_key: nil,
               params: %{work_item_id: "wi_one", delivery_owner_session_key: "lead"}
             })

    assert DeliveryResponsibilities.responsibility(ctx.db, "lead", "wi_one") == "accountable"
  end

  defp delegated_lane(db) do
    session(db, "lane", %{spawned_by: "lead"})
    session(db, "lane-coordinator", %{spawned_by: "lane"})
    associate(db, "lane", "product-owner:reparent", "lane-association")

    assert %{id: assignment_id} =
             Assignments.__handle__(db, "assign", %{
               verb: "assign",
               origin: "agent:lead",
               principal: {:session, "lead"},
               session_key: "lane",
               target_role: nil,
               role_fallback: false,
               supervision_interval_ms: 1_000,
               params: %{
                 subject: "delegate exact work item",
                 idempotency_key: nil,
                 work_item_id: "wi_one",
                 reviews_assignment_id: nil,
                 effect_kind: "coordination",
                 files: nil,
                 delegates_delivery: true
               }
             })

    assert is_binary(assignment_id)
  end

  defp associate(db, target, po_role, key) do
    assert %{"changed" => true} =
             SessionPoAssociations.handle(db, %{
               principal: {:user, "owner"},
               params: %{session_key: target, po_role: po_role, idempotency_key: key}
             })
  end

  defp agent_params(ctx),
    do: %{ctx.params | parent_session_key: "coordinator", idempotency_key: "agent-move"}

  defp agent_call(caller, params),
    do: %{call(params) | principal: {:session, caller}, origin: "agent:" <> caller}

  defp session(db, key, extra \\ %{}) do
    Org.create(
      db,
      Map.merge(
        %{
          session_key: key,
          display_name: key,
          owner_user_id: "owner",
          origin: "user:owner",
          archetype: "default",
          harness: "fixture",
          provider: "fixture_provider",
          model: Model.new("fixture"),
          host: "synthetic-host"
        },
        extra
      )
    )
  end

  defp item(db, id) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO work_items(id,title,ownerUserId,state,createdByUser,createdContextKnown,createdAt)
        VALUES (?1,'synthetic item','owner','open','owner',0,1)
        """,
        [id]
      )
  end

  defp assignment(db, id, holder, item) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,state,workItemId)
        VALUES (?1,'synthetic assignment',?2,'owner',1,'open',?3)
        """,
        [id, holder, item]
      )
  end

  defp call(params),
    do: %{
      principal: {:user, "owner"},
      origin: "user:owner",
      session_key: nil,
      verb: "session-reparent",
      params: params
    }

  defp rows(db, sql) do
    assert {:ok, rows} = DB.query(db, sql)
    rows
  end

  defp count(db, table), do: rows(db, "SELECT COUNT(*) FROM #{table}") |> hd() |> hd()
  defp tree(db), do: Tightbeam.ExecutionMap.roster(db, %{call(%{}) | params: %{tree: true}})

  defp snapshot(db) do
    for table <-
          ~w(sessions assignments work_items turns messages wakes attests artifacts harness_pointers),
        into: %{},
        do: {table, rows(db, "SELECT * FROM #{table} ORDER BY rowid")}
  end
end
