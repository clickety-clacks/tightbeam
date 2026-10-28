defmodule Tightbeam.FirehoseAppBacklogTest do
  use Tightbeam.TestCase, async: false
  import ExUnit.CaptureLog

  alias Tightbeam.Firehose.Hub

  test "credentialless observers receive subscribed notices without revocation" do
    hub = start_supervised!({Hub, name: nil})

    :ok =
      Hub.register(hub, self(), %{
        mode: :filtered,
        principal_kind: :observer,
        principal_id: "observer"
      })

    :ok =
      Hub.subscribe(hub, self(), "revocations", %{
        "classes" => ["device.revoked", "session.retired"]
      })

    Hub.publish(hub, %{"class" => "device.revoked", "refs" => %{}, "payload" => %{}})

    Hub.publish(hub, %{
      "class" => "session.retired",
      "refs" => %{},
      "payload" => %{}
    })

    assert Hub.sequence(hub, self()) == 2

    assert_receive {:firehose_notice,
                    %{
                      "class" => "device.revoked",
                      "seq" => 1,
                      "subscriptionId" => "revocations"
                    }}

    assert_receive {:firehose_notice,
                    %{
                      "class" => "session.retired",
                      "seq" => 2,
                      "subscriptionId" => "revocations"
                    }}

    refute_received :firehose_revoked

    assert %{overflowed: false, queued: 0, seq: 2, in_flight: false} =
             Hub.connection_stats(hub, self())
  end

  test "more than 1,000 queued publications do not trigger a shared ingress drop" do
    hub = start_supervised!({Hub, name: nil})
    counter = :atomics.new(1, signed: false)

    :ok =
      Hub.register(hub, self(), %{
        mode: :filtered,
        principal_kind: :observer,
        backlog_counter: counter
      })

    :ok = Hub.subscribe(hub, self(), "all", %{"classes" => ["message.created"]})
    :ok = :sys.suspend(hub)

    try do
      Enum.each(1..1_001, fn index ->
        Hub.publish(hub, %{
          "class" => "message.created",
          "refs" => %{"workItemId" => "item-#{index}"},
          "payload" => %{"id" => "item-#{index}"}
        })
      end)
    after
      :ok = :sys.resume(hub)
    end

    assert Hub.sequence(hub, self()) == 1_001
    assert %{overflowed: false, queued: 1_001, seq: 1_001} = Hub.connection_stats(hub, self())
    refute_received :firehose_overflow

    assert_receive {:firehose_notice, %{"class" => "message.created", "seq" => 1}}
    assert_receive {:firehose_notice, %{"class" => "message.created", "seq" => 1_001}}
  end

  test "an app over its byte backlog is logged and dropped without dropping another app" do
    hub = start_supervised!({Hub, name: nil})
    counter = :atomics.new(1, signed: false)

    :ok =
      Hub.register(hub, self(), %{
        mode: :filtered,
        principal_kind: :user,
        principal_id: "slow-app",
        user_id: "slow-app",
        backlog_counter: counter
      })

    :ok = Hub.subscribe(hub, self(), "large", %{"classes" => ["large.created"]})

    parent = self()

    healthy_app =
      spawn(fn ->
        counter = :atomics.new(1, signed: false)
        :ok =
          Hub.register(hub, self(), %{
            mode: :filtered,
            principal_kind: :user,
            principal_id: "healthy-app",
            user_id: "healthy-app",
            backlog_counter: counter
          })
        :ok = Hub.subscribe(hub, self(), "small", %{"classes" => ["small.created"]})
        send(parent, {:healthy_ready, self()})

        receive do
          {:firehose_notice, notice} ->
            send(parent, {:healthy_notice, notice})
            receive do
              :stop -> :ok
            end

          :stop ->
            :ok
        end
      end)

    assert_receive {:healthy_ready, ^healthy_app}, 5_000
    on_exit(fn -> if Process.alive?(healthy_app), do: send(healthy_app, :stop) end)

    payload = String.duplicate("x", 33 * 1_024 * 1_024)

    Hub.publish(hub, %{
      "class" => "large.created",
      "refs" => %{},
      "payload" => %{"body" => payload}
    })

    assert Hub.sequence(hub, self()) == 1

    log =
      capture_log(fn ->
        Hub.publish(hub, %{
          "class" => "large.created",
          "refs" => %{},
          "payload" => %{"body" => payload}
        })

        assert Hub.sequence(hub, self()) == 2
      end)

    assert log =~ "firehose app dropped"
    assert log =~ "slow-app"
    assert log =~ "reason=outbound_queue_overflow"
    assert_receive :firehose_overflow, 5_000
    assert_receive {:firehose_notice, %{"class" => "large.created", "seq" => 1}}, 5_000
    assert %{overflowed: true, seq: 2} = Hub.connection_stats(hub, self())

    Hub.publish(hub, %{"class" => "small.created", "refs" => %{}, "payload" => %{}})
    assert Hub.sequence(hub, healthy_app) == 1
    assert_receive {:healthy_notice, %{"class" => "small.created", "seq" => 1}}, 5_000
    refute_received :firehose_overflow
    assert %{overflowed: false, seq: 1} = Hub.connection_stats(hub, healthy_app)
  end
end
