defmodule Tightbeam.BoundedFirehoseIngressTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.DB
  alias Tightbeam.Firehose.{Hub, Publisher}

  setup do
    hub = start_supervised!({Hub, name: nil})
    :ok = Hub.register(hub, self(), %{mode: :all, user_id: "owner", is_admin: true})
    %{hub: hub}
  end

  test "a blocked hub bounds incoming publications by count and signals recovery", %{hub: hub} do
    :ok = :sys.suspend(hub)
    try do
      for _ <- 1..10_000, do: Hub.publish(hub, notice("small"))
      assert {:message_queue_len, count} = Process.info(hub, :message_queue_len)
      assert count <= 1_001
    after
      :sys.resume(hub)
    end
    assert_receive :firehose_overflow, 5_000
    assert %{overflowed: true, queued: 0} = Hub.connection_stats(hub, self())
  end

  test "byte admission also bounds transaction publications", %{hub: hub} do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = :sys.suspend(hub)
    try do
      assert {:ok, :ok} = DB.transaction(db, fn txn ->
        for _ <- 1..100 do
          Publisher.observed_accepted_in_txn(txn, %{verb: "inspect", origin: "user:owner",
            params: %{}, firehose_hub: hub, session_key: String.duplicate("x", 1024 * 1024)})
        end
        :ok
      end)
      assert {:message_queue_len, count} = Process.info(hub, :message_queue_len)
      assert count <= 8
    after
      :sys.resume(hub)
    end
    assert_receive :firehose_overflow, 5_000
  end

  test "nonmatching subscriptions never query visibility", %{hub: hub} do
    :ok = Hub.register(hub, self(), %{mode: :subscribed, db: :unavailable_database, is_admin: false})
    :ok = Hub.subscribe(hub, self(), "work", %{"classes" => ["work_item."]})
    Hub.publish(hub, notice("unmatched"))
    assert Hub.sequence(hub, self()) == 0
    assert Process.alive?(hub)
    refute_receive {:firehose_notice, _}
  end

  test "each matching notice checks visibility once before fanout to subscriptions", %{hub: hub} do
    :ok = Hub.register(hub, self(), %{mode: :subscribed})
    :ok = Hub.subscribe(hub, self(), "one", %{})
    :ok = Hub.subscribe(hub, self(), "two", %{})
    :erlang.trace_pattern({Tightbeam.StateVisibility, :visible?, 4}, true, [])
    :erlang.trace(hub, true, [:call])
    try do
      Hub.publish(hub, notice("matching"))
      assert_receive {:firehose_notice, %{"subscriptionId" => "one"}}
      Hub.delivered(hub, self())
      assert_receive {:firehose_notice, %{"subscriptionId" => "two"}}
      assert_receive {:trace, ^hub, :call, {Tightbeam.StateVisibility, :visible?, _}}
      refute_receive {:trace, ^hub, :call, {Tightbeam.StateVisibility, :visible?, _}}
    after
      :erlang.trace(hub, false, [:call])
      :erlang.trace_pattern({Tightbeam.StateVisibility, :visible?, 4}, false, [])
    end
  end

  defp notice(value), do: %{"class" => "verb.accepted", "refs" => %{}, "payload" => %{"value" => value}}
end
