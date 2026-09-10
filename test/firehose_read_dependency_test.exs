defmodule Tightbeam.FirehoseReadDependencyTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, ReadMarkers}
  alias Tightbeam.Firehose.Hub

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = ReadMarkers.ensure_schema(db)
    hub = start_supervised!({Hub, name: nil})

    :ok =
      Hub.register(hub, self(), %{mode: :all, db: db, user_id: "synthetic-owner", is_admin: true})

    %{db: db, hub: hub}
  end

  @tag rest_r7_closure: true
  test "B2 canonical priority preserves numeric boundaries and rejects malformed values", %{
    db: db
  } do
    alias Tightbeam.{Schema, StateResources, WorkItems}
    :ok = Schema.ensure_all(db)

    work =
      WorkItems.__handle__(db, "work-item-create", %{
        principal: {:user, "synthetic-owner"},
        params: %{title: "priority boundary", priority: 4}
      })

    principal = %{rest_principal: %{kind: "user", id: "synthetic-owner", is_admin: false}}
    row = db |> StateResources.query_work_item(work.id, principal) |> StateResources.work_item()

    for priority <- [0, 4, 8] do
      item = Map.put(row, "priority", priority)
      bytes = StateResources.encode_item("work items", item, %{})
      assert JSON.decode!(bytes) == item
      assert bytes =~ "\"priority\":#{priority},\"rowVersion\":"
    end

    for priority <- [nil, "4", 4.5, -1, 9] do
      assert_raise ArgumentError, fn ->
        StateResources.encode_item("work items", Map.put(row, "priority", priority), %{})
      end
    end

    assert_raise ArgumentError, fn ->
      StateResources.encode_item("work items", Map.delete(row, "priority"), %{})
    end

    assert db |> StateResources.query_work_item(work.id, principal) |> StateResources.work_item() ==
             row
  end

  @tag rest_r7_encoder: true
  test "R7 message notices reject the historical partial shape and additive drift" do
    alias Tightbeam.Firehose.Publisher

    legacy = %{
      "id" => "s_legacy",
      "seq" => 1,
      "sessionKey" => "agent:legacy",
      "role" => "assistant",
      "content" => "legacy",
      "timestamp" => 1,
      "sender" => "tightbeam",
      "deviceId" => nil,
      "clientMessageId" => nil,
      "replyToMessageId" => nil,
      "replyToClientMessageId" => nil,
      "llmVisibleMessageId" => "s_legacy",
      "attachments" => [],
      "attentionTier" => 0,
      "rowVersion" => 1
    }

    for {payload, error} <- [
          {legacy, ~r/no permitted legacy partial shape/},
          {Map.put(legacy, "messageType", nil), "messageType must be a string when present"},
          {Map.put(legacy, "extra", true), ~r/no permitted legacy partial shape/}
        ] do
      assert_raise ArgumentError, error, fn ->
        Publisher.encode_wire_notice(
          %{"class" => "message.created", "op" => "upsert", "payload" => payload},
          %{}
        )
      end
    end
  end

  test "real read-marker commit publishes once, no-op and stale CAS do not publish state", %{
    db: db,
    hub: hub
  } do
    call = %{
      verb: "read-marker-set",
      params: %{scope_key: "work:one"},
      principal: {:user, "synthetic-owner"},
      firehose_in_txn: true,
      firehose_hub: hub
    }

    assert {:ok, true, first} =
             ReadMarkers.set(db, "synthetic-owner", "work:one", "one", firehose_call: call)

    assert ReadMarkers.get(db, "synthetic-owner", "work:one") == first
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    assert_receive {:firehose_notice, %{"class" => "read_marker.updated", "payload" => payload}}
    assert payload["marker"] == "one"
    assert payload["rowVersion"] == first.updated_at
    assert payload["userId"] == "synthetic-owner"
    Hub.delivered(hub, self())

    assert {:ok, false, ^first} =
             ReadMarkers.set(db, "synthetic-owner", "work:one", "one", firehose_call: call)

    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    refute_receive {:firehose_notice, %{"class" => "read_marker.updated"}}

    assert {:error, %{code: "read_marker_conflict"}} =
             ReadMarkers.set(db, "synthetic-owner", "work:one", "two",
               expected?: true,
               expected: "wrong",
               firehose_call: call
             )

    refute_receive {:firehose_notice, _}
    assert ReadMarkers.get(db, "synthetic-owner", "work:one") == first
    assert ReadMarkers.get(db, "another-owner", "work:one") == nil
  end

  test "clearing preserves monotonic version and transaction reads use the same row", %{db: db} do
    assert {:ok, true, first} = ReadMarkers.set(db, "synthetic-owner", "work:one", "one")

    assert {:ok, true, cleared} =
             ReadMarkers.set(db, "synthetic-owner", "work:one", nil,
               expected?: true,
               expected: "one"
             )

    assert cleared.marker == nil
    assert cleared.updated_at > first.updated_at

    assert {:ok, ^cleared} =
             DB.transaction(db, &ReadMarkers.get_in_txn(&1, "synthetic-owner", "work:one"))
  end

  test "R7 return triplets refuse malformed rows at projection and encoding" do
    alias Tightbeam.StateResources

    fields =
      ~w(id kind raiserId raiserSessionKey ownerUserId assignmentId expecterSessionKey expecterUserId lineageRung effortGeneration deadlineWakeId raisedAt deadlineAt statuteName question options context status decision rationale ruledBy ruledAt consumedAt withdrawnBy withdrawnReason withdrawnAt askedOfRole answer answeredBy answeredAt returnedBy returnReason returnedAt rowVersion)

    raw =
      Map.new(fields, &{&1, nil})
      |> Map.merge(%{
        "id" => "r7-agent",
        "kind" => "agent",
        "question" => "Which path?",
        "status" => "open",
        "raisedAt" => 1,
        "rowVersion" => 1
      })

    open = StateResources.decision_request(raw)
    assert JSON.decode!(StateResources.encode_item("decision requests", open, %{})) == open

    returned =
      Map.merge(raw, %{
        "status" => "returned",
        "returnedBy" => "owner",
        "returnReason" => "retry",
        "returnedAt" => 2
      })

    item = StateResources.decision_request(returned)
    bytes = StateResources.encode_item("decision requests", item, %{})
    assert JSON.decode!(bytes) == item

    assert bytes =~
             "\"answeredAt\":null,\"returnedBy\":\"owner\",\"returnReason\":\"retry\",\"returnedAt\":2"

    for changes <- [
          %{"returnedBy" => ""},
          %{"returnedBy" => " \t"},
          %{"returnReason" => ""},
          %{"returnReason" => " \n"},
          %{"returnedAt" => 0},
          %{"returnedAt" => -1},
          %{"returnedAt" => nil},
          %{"returnedBy" => nil},
          %{"status" => "open"}
        ] do
      assert_raise ArgumentError, fn ->
        StateResources.decision_request(Map.merge(returned, changes))
      end

      assert_raise ArgumentError, fn ->
        StateResources.encode_item("decision requests", Map.merge(item, changes), %{})
      end
    end

    assert_raise ArgumentError, fn ->
      StateResources.decision_request(Map.put(raw, "status", "returned"))
    end

    assert StateResources.decision_request(raw) == open
  end

  test "B2 selection shares priority and tenant filtering with detail", %{db: db} do
    alias Tightbeam.{Schema, StateResources, WorkItems}
    :ok = Schema.ensure_all(db)

    create = fn owner, title, priority ->
      WorkItems.__handle__(db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:" <> owner,
        principal: {:user, owner},
        session_key: nil,
        params: %{title: title, priority: priority}
      })
    end

    first = create.("synthetic-owner", "first", 2)
    second = create.("synthetic-owner", "second", 7)
    foreign = create.("other-owner", "foreign", 4)
    principal = %{rest_principal: %{kind: "user", id: "synthetic-owner", is_admin: false}}
    rows = StateResources.query_work_item(db, %{}, principal)
    assert MapSet.new(Enum.map(rows, & &1.id)) == MapSet.new([first.id, second.id])
    assert StateResources.query_work_item(db, foreign.id, principal) == nil
    assert StateResources.query_work_item(db, %{"ownerUserId" => "other-owner"}, principal) == []

    for row <- rows do
      assert StateResources.query_work_item(db, row.id, principal) == row
      item = StateResources.work_item(row)
      assert item["priority"] in [2, 7]
      assert JSON.decode!(StateResources.encode_item("work items", item, %{})) == item

      assert_raise ArgumentError, fn ->
        StateResources.encode_item("work items", Map.put(item, "priority", 9), %{})
      end
    end

    assert Enum.map(StateResources.query_work_item(db, %{"state" => "open"}, principal), & &1.id) ==
             Enum.map(rows, & &1.id)
  end

  test "R7 transcript query joins the user turn and preserves reply linkage", %{db: db} do
    alias Tightbeam.{Schema, Org, Model, Projection, Ledger, StateResources}
    :ok = Schema.ensure_all(db)

    Org.create(db, %{
      session_key: "r7-message",
      display_name: "synthetic",
      owner_user_id: "synthetic-owner",
      origin: "user:synthetic-owner",
      archetype: "default",
      host: "synthetic-host",
      harness: "fixture",
      provider: "fixture_provider",
      model: Model.new("fixture-model")
    })

    assert {:appended, user} =
             Projection.append(db, %{
               session_key: "r7-message",
               role: "user",
               content: "question",
               timestamp: 10,
               client_message_id: "r7-client",
               attachments: []
             })

    assert {:ok, turn} =
             Ledger.enqueue(db, %{
               session_key: "r7-message",
               message_id: user.id,
               origin: "user:synthetic-owner",
               prompt: "question"
             })

    assert {:appended, reply} =
             Projection.append(db, %{
               session_key: "r7-message",
               role: "assistant",
               content: "answer",
               timestamp: 11,
               reply_to_message_id: user.id,
               reply_to_client_message_id: "r7-client",
               attachments: []
             })

    for message <- [user, reply] do
      row = StateResources.query_message(db, message.id)
      assert row.turn_seq == turn
      assert {:ok, ^row} = DB.transaction(db, &StateResources.query_message(&1, message.id))
      item = StateResources.message(row)
      assert item["at"] == message.timestamp
      assert item["turnSeq"] == turn
      assert item["rowVersion"] == message.seq
      assert item["content"] == message.content
      assert JSON.decode!(StateResources.encode_item("transcript messages", item, %{})) == item
    end

    assert StateResources.query_message(db, reply.id).reply_to_message_id == user.id
    assert StateResources.query_message(db, "absent-message") == nil

    assert {:ok, {:appended, _}} =
             DB.transaction(db, fn txn ->
               Projection.append_in_txn(txn, %{
                 session_key: "r7-message",
                 role: "user",
                 content: "other",
                 timestamp: 12,
                 attachments: []
               })
             end)
  end
end
