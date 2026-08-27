defmodule Tightbeam.Firehose.RetireCommitOrderTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConnRegistry, DB, Dispatch, Gateway, Model, Org, Wakes}
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
