defmodule Tightbeam.BoundedFirehoseIngressTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Hub

  setup do
    hub = start_supervised!({Hub, name: nil})
    :ok = Hub.register(hub, self(), %{mode: :all, user_id: "owner"})
    %{hub: hub}
  end

  test "shared publication ingress does not close a filtered subscriber", %{hub: hub} do
    :ok = Hub.register(hub, self(), %{mode: :subscribed})
    :ok = Hub.subscribe(hub, self(), "quiet", %{"classes" => ["never."]})
    :ok = :sys.suspend(hub)

    try do
      for index <- 1..1_500 do
        Hub.publish(hub, notice("work_item.updated", %{"id" => "item-#{index}"}))
      end
    after
      :ok = :sys.resume(hub)
    end

    assert Hub.sequence(hub, self()) == 0
    assert Process.alive?(hub)
    refute_receive :firehose_overflow
    refute_receive {:firehose_notice, _}
  end

  test "transaction handoff has no shared byte admission cap", %{hub: hub} do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    large_value = String.duplicate("x", 1024 * 1024)
    event = notice("verb.accepted", %{"value" => large_value})
    :ok = :sys.suspend(hub)

    try do
      assert {:ok, :queued} =
               DB.transaction(db, fn txn ->
                 for _ <- 1..9 do
                   Txn.handoff(txn, Hub.destination(hub), {:publish, event})
                 end

                 :queued
               end)
    after
      :ok = :sys.resume(hub)
    end

    for _ <- 1..9 do
      assert_receive {:firehose_notice, %{"payload" => %{"value" => ^large_value}}}, 5_000
    end

    refute_receive :firehose_overflow
  end

  test "matching subscriptions fan out without per-notice visibility reads", %{hub: hub} do
    :ok = Hub.register(hub, self(), %{mode: :subscribed, db: :unavailable_database})
    :ok = Hub.subscribe(hub, self(), "one", %{"classes" => ["work_item."]})
    :ok = Hub.subscribe(hub, self(), "two", %{"classes" => ["work_item."]})
    Code.ensure_loaded!(Tightbeam.StateVisibility)
    assert :erlang.trace_pattern({Tightbeam.StateVisibility, :visible?, 4}, true, []) == 1
    :erlang.trace(hub, true, [:call])

    try do
      Hub.publish(hub, notice("work_item.updated", %{"id" => "matching"}))
      assert_receive {:firehose_notice, %{"subscriptionId" => "one"}}
      assert_receive {:firehose_notice, %{"subscriptionId" => "two"}}
      refute_receive {:trace, ^hub, :call, {Tightbeam.StateVisibility, :visible?, _}}
    after
      :erlang.trace(hub, false, [:call])
      :erlang.trace_pattern({Tightbeam.StateVisibility, :visible?, 4}, false, [])
    end
  end

  test "one slow subscriber overflows without closing a draining subscriber" do
    hub = start_supervised!({Hub, name: nil}, id: :isolated_hub)
    parent = self()

    fast =
      spawn(fn ->
        receive_notice = fn receive_notice ->
          receive do
            :stop ->
              :ok

            {:firehose_notice, %{"seq" => seq}} ->
              send(parent, {:fast_notice, seq})
              receive_notice.(receive_notice)

            :firehose_overflow ->
              send(parent, :fast_overflow)
              receive_notice.(receive_notice)
          end
        end

        receive_notice.(receive_notice)
      end)

    on_exit(fn ->
      if Process.alive?(fast), do: send(fast, :stop)
    end)

    :ok =
      Hub.register(hub, self(), %{
        mode: :subscribed,
        user_id: "slow-user",
        device_id: "slow-device",
        principal_kind: :user,
        principal_id: "slow-user"
      })

    :ok = Hub.subscribe(hub, self(), "slow", %{})
    :ok = Hub.register(hub, fast, %{mode: :subscribed})
    :ok = Hub.subscribe(hub, fast, "fast", %{})

    under_limit_value = String.duplicate("x", 63 * 1_024 * 1_024)
    over_limit_value = String.duplicate("y", 2 * 1_024 * 1_024)

    Hub.publish(
      hub,
      notice("work_item.updated", %{"id" => "first", "value" => under_limit_value})
    )

    assert Hub.sequence(hub, self()) == 1
    assert_receive {:fast_notice, 1}
    refute_receive :firehose_overflow

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Hub.publish(
          hub,
          notice("work_item.updated", %{"id" => "second", "value" => over_limit_value})
        )

        assert Hub.sequence(hub, self()) == 2
        assert_receive {:fast_notice, 2}
      end)

    assert log =~ "principal_kind: :user"
    assert log =~ "principal_id: \"slow-user\""
    assert log =~ "device_id: \"slow-device\""
    assert log =~ "reason=outbound_queue_overflow"
    assert log =~ "limit_bytes=67108864 close_code=4008"
    assert [_, backlog_bytes] = Regex.run(~r/backlog_bytes=(\d+)/, log)
    assert String.to_integer(backlog_bytes) > 64 * 1_024 * 1_024

    assert_receive {:firehose_notice, %{"seq" => 1}}
    assert_receive :firehose_overflow
    assert %{overflowed: true} = Hub.connection_stats(hub, self())
    refute_receive :fast_overflow
    assert Process.alive?(fast)
  end

  test "shutdown delivers its signal after queued publications", %{hub: hub} do
    parent = self()
    task = Task.async(fn -> Hub.shutdown(hub, System.monotonic_time(:millisecond) + 1_000) end)
    assert_receive :firehose_shutdown
    assert :ok = Hub.shutdown_delivered(hub, parent)
    assert Task.await(task) == :ok
  end

  defp notice(class, payload),
    do: %{"class" => class, "refs" => %{}, "payload" => payload}
end
