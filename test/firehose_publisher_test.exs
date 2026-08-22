defmodule Tightbeam.Firehose.PublisherTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Dispatch, Gateway, Rules, Wakes}
  alias Tightbeam.Firehose.{Hub, Publisher}

  setup do
    :persistent_term.erase(Rules)
    start_supervised!({Hub, name: Hub})
    :ok = Hub.register(Hub, self())
    on_exit(fn -> :persistent_term.erase(Rules) end)
    :ok
  end

  test "work-item-create emits its committed routing wake once, never on keyed replay" do
    db = :firehose_work_item_create_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users VALUES ('flynn', 1, 1)")

    handlers = Gateway.handlers(%{db: db})

    call = %{
      verb: "work-item-create",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{title: "Route this", idempotency_key: "firehose-create"}
    }

    assert {:ok, item} = Dispatch.dispatch(db, handlers, call)

    assert_receive {:firehose_notice,
                    %{
                      "class" => "wake.scheduled",
                      "refs" => %{"wakeId" => wake_id, "workItemId" => work_item_id}
                    }}

    assert work_item_id == item.id
    assert Wakes.get(db, wake_id).work_item_id == item.id
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    assert_receive {:firehose_notice, %{"class" => "work_item.created"}}

    assert {:ok, replay} = Dispatch.dispatch(db, handlers, call)
    assert replay.id == item.id
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    assert_receive {:firehose_notice, %{"class" => "work_item.created"}}
    refute_receive {:firehose_notice, %{"class" => "wake.scheduled"}}
  end

  test "a raised state handler emits denied and never accepted state effects" do
    db = :firehose_raised_handler_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    call = %{
      verb: "work-item-create",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{title: "Will raise"}
    }

    assert {:error, %{code: "server_error", message: "review boom"}} =
             Dispatch.dispatch(db, %{"work-item-create" => fn _ -> raise "review boom" end}, call)

    assert_receive {:firehose_notice,
                    %{
                      "class" => "verb.denied",
                      "payload" => %{"code" => "server_error", "verb" => "work-item-create"}
                    }}

    refute_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    refute_receive {:firehose_notice, %{"class" => "work_item.created"}}
  end

  test "an accepted state verb emits its observation and canonical state notice" do
    call = %{
      verb: "work-item-update",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{work_item_id: "wi_1"}
    }

    result = %{
      id: "wi_1",
      title: "Firehose",
      owner_user_id: "flynn",
      updated_at: 123,
      cli_token: "must-not-leak"
    }

    assert :ok = Publisher.accepted(call, result)

    assert_receive {:firehose_notice,
                    %{"class" => "verb.accepted", "op" => "observe", "refs" => refs}}

    assert refs["origin"] == "user:flynn"

    assert_receive {:firehose_notice,
                    %{
                      "class" => "work_item.updated",
                      "resource" => "work-items",
                      "op" => "upsert",
                      "refs" => %{"workItemId" => "wi_1"},
                      "payload" => payload
                    }}

    assert payload["id"] == "wi_1"
    assert payload["rowVersion"] == 123
    refute Map.has_key?(payload, "cliToken")
  end

  test "unmapped reads emit only the observational verb notice" do
    assert :ok =
             Publisher.accepted(
               %{verb: "assignments", origin: "user:flynn", params: %{}},
               %{assignments: []}
             )

    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    refute_receive {:firehose_notice, _notice}
  end

  test "a committed row uses the registry serializer and primary ref" do
    assert :ok =
             Publisher.committed(
               "message.created",
               %{id: "s_1", seq: 9, session_key: "agent:one", content: "hello"},
               %{"ownerUserId" => "flynn", "sessionKey" => "agent:one"}
             )

    assert_receive {:firehose_notice,
                    %{
                      "class" => "message.created",
                      "refs" => %{"messageId" => "s_1"},
                      "payload" => %{"id" => "s_1", "rowVersion" => 9}
                    }}
  end

  test "a role delete carries its last visible pre-delete row" do
    db = :firehose_role_delete_db
    start_supervised!({Tightbeam.DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, _} = Tightbeam.DB.query(db, "INSERT INTO users VALUES ('flynn', 1, 1)")
    %{name: "worker"} = Tightbeam.Roles.create!(db, "worker", "flynn", nil)

    call = %{
      verb: "role-rm",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      params: %{name: "worker"}
    }

    captured = Publisher.capture_before(db, call)
    :ok = Tightbeam.Roles.rm(db, "worker")
    :ok = Publisher.accepted(db, captured, %{removed: "worker"})

    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}

    assert_receive {:firehose_notice,
                    %{
                      "class" => "role.removed",
                      "op" => "delete",
                      "refs" => %{"role" => "worker"},
                      "payload" => %{"role" => "worker", "ownerUserId" => "flynn"}
                    }}
  end

  test "a rail denial emits both observational classes" do
    call = %{
      verb: "attest",
      origin: "agent:worker",
      principal: {:session, "agent:worker"},
      session_key: "agent:worker",
      params: %{}
    }

    :ok = Publisher.denied(call, %{code: "rule_denied", rule: "tests-before-success"})

    assert_receive {:firehose_notice, %{"class" => "verb.denied"}}

    assert_receive {:firehose_notice,
                    %{
                      "class" => "rail.denied",
                      "payload" => %{"rule" => "tests-before-success", "verb" => "attest"}
                    }}
  end

  test "condition and critical projections carry stable ids and last-version-wins" do
    older_fact = Tightbeam.StateResources.condition_fact(%{fact_id: 4, ts: 100, kind: "ready"})
    newer_fact = Tightbeam.StateResources.condition_fact(%{fact_id: 5, ts: 90, kind: "ready"})
    assert older_fact["factId"] == older_fact["rowVersion"]
    assert newer_fact["factId"] == newer_fact["rowVersion"]
    assert lww(older_fact, newer_fact) == newer_fact
    assert lww(newer_fact, older_fact) == newer_fact
    assert lww(newer_fact, newer_fact) == newer_fact

    older_lease =
      Tightbeam.StateResources.critical_state(%{session_key: "agent:one", updated_at: 10})

    newer_lease =
      Tightbeam.StateResources.critical_state(%{session_key: "agent:one", updated_at: 11})

    assert lww(older_lease, newer_lease) == newer_lease
    assert lww(newer_lease, older_lease) == newer_lease
    assert lww(newer_lease, newer_lease) == newer_lease
  end

  defp lww(current, candidate) do
    if candidate["rowVersion"] >= current["rowVersion"], do: candidate, else: current
  end
end
