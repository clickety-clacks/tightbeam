defmodule Tightbeam.DirectFirehoseFanoutTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.Firehose.Hub

  test "matching subscriptions receive every frame without a delivery handshake or permission lookup" do
    hub = start_supervised!({Hub, name: nil})

    :ok =
      Hub.register(hub, self(), %{
        mode: :filtered,
        principal_kind: :user,
        principal_id: "reader",
        user_id: "reader"
      })

    :ok = Hub.subscribe(hub, self(), "one", %{"classes" => ["work_item."]})
    :ok = Hub.subscribe(hub, self(), "two", %{"classes" => ["work_item."]})

    Hub.publish(hub, %{
      "class" => "work_item.updated",
      "refs" => %{"workItemId" => "item-1"},
      "payload" => %{"id" => "item-1"}
    })

    assert Hub.sequence(hub, self()) == 2
    assert_receive {:firehose_notice, %{"subscriptionId" => "one", "seq" => 1}}
    assert_receive {:firehose_notice, %{"subscriptionId" => "two", "seq" => 2}}
    refute_received :firehose_overflow
    assert %{overflowed: false, queued: 0, seq: 2, in_flight: false} =
             Hub.connection_stats(hub, self())
  end
end
