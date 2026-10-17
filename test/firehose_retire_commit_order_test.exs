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
    :ok
  end

  test "critical Dispatch publishes its committed bounded lease and rejects user impersonation" do
    db = :firehose_critical_dispatch_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn',1,1)")
    register_testhost(db)
    worker = create_session(db, "critical-worker", Org.personal_session_key("flynn"))
    handlers = Gateway.handlers(%{db: db, critical_lease_hard_cap_ms: 20_000})

    call = %{
      verb: "critical",
      origin: "agent:critical-worker",
      principal: {:session, worker.session_key},
      session_key: worker.session_key,
      # The worst observed dispatch/notice path was 1_453 ms. A 12-second arm
      # leaves more than 10 seconds of load margin, while two active arms still
      # exceed the 20-second hard cap and exercise the renewal clamp.
      params: %{for_ms: 12_000, reason: "synthetic critical proof"}
    }

    _ = receive_notices()
    assert {:ok, first} = Dispatch.dispatch(db, handlers, call)
    first_stored = Tightbeam.CriticalLeases.get(db, worker.session_key)
    assert {:ok, renewed} = Dispatch.dispatch(db, handlers, call)
    stored = Tightbeam.CriticalLeases.get(db, worker.session_key)

    assert first.expires_at < first.hard_deadline
    assert renewed.hard_deadline == first.hard_deadline
    assert stored.hard_deadline == first.hard_deadline
    assert renewed.expires_at == first.hard_deadline
    assert stored.expires_at == first.hard_deadline

    notices = receive_notices()

    assert Enum.map(notices, & &1["class"]) == [
             "verb.accepted",
             "critical_lease.updated",
             "verb.accepted",
             "critical_lease.updated"
           ]

    assert Enum.at(notices, 1)["payload"] == StateResources.critical_state(first_stored)
    assert List.last(notices)["payload"] == StateResources.critical_state(stored)

    before = stored

    assert {:error, _} =
             Dispatch.dispatch(db, handlers, %{
               call
               | principal: {:user, "flynn"},
                 origin: "user:flynn"
             })

    assert Tightbeam.CriticalLeases.get(db, worker.session_key) == before
    refute Enum.any?(receive_notices(), &(&1["class"] == "critical_lease.updated"))
  end

  test "deferred retirement emits its new wake and no false session retirement" do
    db = :firehose_deferred_retire_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users (userId,isAdmin,createdAt) VALUES ('flynn', 1, 1)")
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
    {:ok, _} = DB.query(db, "INSERT INTO users (userId,isAdmin,createdAt) VALUES ('flynn', 1, 1)")
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

  defp create_session(db, session_key, spawned_by) do
    Org.create(db, %{
      session_key: session_key,
      display_name: session_key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      spawned_by: spawned_by,
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp register_testhost(db) do
    :ok =
      Hub.register(Hub, self(), %{
        mode: :all,
        db: db,
        user_id: "synthetic-reviewer",
        is_admin: true
      })

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
