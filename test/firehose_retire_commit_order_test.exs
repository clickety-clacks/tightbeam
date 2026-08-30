defmodule Tightbeam.Firehose.RetireCommitOrderTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Assignments,
    ConnRegistry,
    DB,
    Dispatch,
    Gateway,
    Ledger,
    Model,
    Org,
    Schema,
    StateResources,
    Supervision,
    Wakes
  }

  alias Tightbeam.Firehose.Hub

  setup do
    start_supervised!({Hub, name: Hub})
    start_supervised!({ConnRegistry, name: ConnRegistry})
    :ok = Hub.register(Hub, self(), %{mode: :all, user_id: "reviewer"})
    :ok
  end

  test "deferred retirement emits its new wake and no false session retirement" do
    db = :firehose_deferred_retire_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES ('flynn',1,'admin_add',1)"
      )

    register_testhost(db)

    root = create_session(db, "firehose-deferred-root", nil)
    child = create_session(db, "firehose-deferred-child", root.session_key)

    handlers =
      Gateway.handlers(%{
        db: db,
        wake_tick_ms: 1_000,
        critical_lease_hard_cap_ms: 20_000
      })

    assert {:ok, _lease} =
             Dispatch.dispatch(db, handlers, %{
               verb: "critical",
               origin: "agent:firehose-deferred-child",
               principal: {:session, child.session_key},
               session_key: child.session_key,
               params: %{for_ms: 10_000, reason: "review hold"}
             })

    _ = receive_notices()

    call = %{
      verb: "retire",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: root.session_key,
      params: %{}
    }

    assert {:ok, %{retired_session_keys: [], deferred: deferred}} =
             Dispatch.dispatch(db, handlers, call)

    assert Enum.map(deferred, & &1.session_key) == [child.session_key, root.session_key]
    assert Org.get(db, root.session_key).state == "active"
    assert Org.get(db, child.session_key).state == "active"
    assert [wake] = Wakes.list_pending(db)
    assert wake.session_key == child.session_key

    assert receive_notices() |> Enum.map(& &1["class"]) == [
             "verb.accepted",
             "wake.scheduled"
           ]

    assert {:ok, %{retired_session_keys: []}} = Dispatch.dispatch(db, handlers, call)

    assert receive_notices() |> Enum.map(& &1["class"]) == ["verb.accepted"]
  end

  test "subtree retirement emits one committed session notice per retired row" do
    db = :firehose_subtree_retire_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES ('flynn',1,'admin_add',1)"
      )

    register_testhost(db)

    root = create_session(db, "firehose-retired-root", nil)
    child = create_session(db, "firehose-retired-child", root.session_key)
    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000, base_dir: System.tmp_dir!()})

    call = %{
      verb: "retire",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: root.session_key,
      params: %{}
    }

    assert {:ok, result} = Dispatch.dispatch(db, handlers, call)

    assert Enum.sort(result.retired_session_keys) ==
             Enum.sort([root.session_key, child.session_key])

    assert Org.get(db, root.session_key).state == "retired"
    assert Org.get(db, child.session_key).state == "retired"

    notices = receive_notices()

    assert Enum.map(notices, & &1["class"]) == [
             "verb.accepted",
             "session.retired",
             "session.retired"
           ]

    assert notices
           |> Enum.filter(&(&1["class"] == "session.retired"))
           |> Enum.map(&get_in(&1, ["payload", "sessionKey"]))
           |> Enum.sort() == Enum.sort([root.session_key, child.session_key])

    assert {:ok, %{retired_session_keys: []}} = Dispatch.dispatch(db, handlers, call)
    assert receive_notices() |> Enum.map(& &1["class"]) == ["verb.accepted"]
  end

  test "retirement with a queued supervision transfer emits only the final session class" do
    db = :firehose_transfer_retire_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES ('flynn',1,'admin_add',1)"
      )

    register_testhost(db)
    main_key = Org.personal_session_key("flynn")
    _supervisor = create_session(db, "transfer-supervisor", main_key)
    _holder = create_session(db, "transfer-holder", "transfer-supervisor")

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO work_items (id,title,ownerUserId,state,createdByUser,createdAt) VALUES ('wi_transfer','work','flynn','open','flynn',1)"
      )

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt,workItemId) VALUES ('asg_transfer','ship','transfer-holder','flynn',1,'wi_transfer')"
      )

    terminal_seq = terminal_turn(db, "transfer-holder", "asg_transfer")
    insert_entitlement(db, "asg_transfer")
    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 60_000})

    assert {:escalated, 1, "transfer-supervisor"} =
             Supervision.evaluate(db, handlers, 0, "transfer-holder", terminal_seq)

    [source_wake] = Wakes.list_pending(db)

    assert {:ok, {:appended, "transfer-supervisor", _message, _opts}} =
             DB.transaction(db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 source_wake.session_key,
                 source_wake.origin,
                 source_wake.prompt,
                 wake_id: source_wake.wake_id,
                 sender: source_wake.origin,
                 target_gate: source_wake,
                 fire_wake_in_txn: true,
                 assignment_id: source_wake.assignment_id
               )
             end)

    _ = receive_notices()

    assert {:ok, retired} =
             DB.transaction(db, fn txn ->
               Assignments.interrupt_for_retire_in_txn(
                 txn,
                 "transfer-supervisor",
                 "flynn",
                 "user:flynn"
               )

               Org.retire_in_txn(txn, "transfer-supervisor", "user:flynn", 1_000)
             end)

    notices =
      receive_notices()
      |> Enum.filter(&(get_in(&1, ["refs", "sessionKey"]) == "transfer-supervisor"))

    assert Enum.map(notices, & &1["class"]) == ["session.retired"]
    assert hd(notices)["payload"] == StateResources.session(retired)
    assert hd(notices)["payload"]["state"] == "retired"
    assert hd(notices)["payload"]["mechanicalStatus"] == "idle"
  end

  defp create_session(db, session_key, spawned_by) do
    Org.create(db, %{
      session_key: session_key,
      display_name: session_key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      spawned_by: spawned_by,
      operational_parent: spawned_by,
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp register_testhost(db) do
    register_hosts(db, %{
      "testhost" => %{ssh: nil, base_dir: System.tmp_dir!(), cli_bin: nil}
    })

    Org.create(db, %{
      session_key: Org.personal_session_key("flynn"),
      display_name: "Main",
      kind: "main",
      is_built_in: true,
      adopted: true,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp terminal_turn(db, session_key, assignment_id) do
    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: "terminal-#{assignment_id}",
        origin: "user:flynn",
        prompt: "external",
        assignment_id: assignment_id
      })

    assert {:ok, %{seq: ^seq, owner_lease: owner_lease}} =
             Ledger.claim_next(db, session_key, "retire-regression")

    assert :ok = Ledger.finish(db, seq, "delivered", nil, owner_lease: owner_lease)
    seq
  end

  defp insert_entitlement(db, assignment_id) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO supervision_entitlements (assignmentId,generation,dueAt,state,basisKind,basisId,cause,principal,supervisionIntervalMs) VALUES (?1,1,0,'armed','assignment_open',?1,'assignment_open','process:tightbeam',60000)",
        [assignment_id]
      )

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO supervision_liveness_receipt_state (assignmentId,artifactCursor,attestCursor,workItemEventCursor,wakeCursor,baselineCause,baselinePrincipal) VALUES (?1,0,0,0,0,'assignment_open','process:tightbeam')",
        [assignment_id]
      )
  end

  defp receive_notices(acc \\ []) do
    receive do
      {:firehose_notice, notice} ->
        Hub.delivered(Hub, self())
        receive_notices([notice | acc])
    after
      500 -> Enum.reverse(acc)
    end
  end
end
