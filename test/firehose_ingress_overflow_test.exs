defmodule Tightbeam.FirehoseIngressOverflowTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Firehose.Hub}

  test "shared ingress overflow closes only subscribers that could miss a matching notice" do
    db = :"firehose_ingress_overflow_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn', 1, 1)")

    hub = start_supervised!({Hub, name: nil})
    register_subscriber!(hub, db, self(), "idle-session", "idle")

    parent = self()

    affected_subscriber =
      spawn(fn ->
        register_subscriber!(hub, db, self(), "session-1001", "affected")
        send(parent, {:subscriber_ready, self()})

        receive do
          :firehose_overflow ->
            send(parent, {:subscriber_overflowed, self()})

            receive do
              :stop -> :ok
            end

          :stop ->
            :ok
        end
      end)

    assert_receive {:subscriber_ready, ^affected_subscriber}, 5_000
    on_exit(fn ->
      if Process.alive?(affected_subscriber), do: send(affected_subscriber, :stop)
    end)

    :ok = :sys.suspend(hub)

    try do
      Enum.each(1..1_000, fn index ->
        session_key = "session-#{index}"

        Hub.publish(hub, %{
          "class" => "message.created",
          "refs" => %{
            "messageId" => "message-#{index}",
            "sessionKey" => session_key,
            "ownerUserId" => "flynn"
          },
          "payload" => %{
            "id" => "message-#{index}",
            "sessionKey" => session_key,
            "ownerUserId" => "flynn"
          }
        })
      end)

      Hub.publish(hub, %{
        "class" => "message.created",
        "refs" => %{
          "messageId" => "message-1001",
          "sessionKey" => "session-1001",
          "ownerUserId" => "flynn"
        },
        "payload" => %{
          "id" => "message-1001",
          "sessionKey" => "session-1001",
          "ownerUserId" => "flynn"
        }
      })

      Hub.publish(hub, %{
        "class" => "device.revoked",
        "refs" => %{"deviceId" => "other-device"},
        "payload" => %{"deviceId" => "other-device"}
      })

      Hub.publish(hub, %{
        "class" => "session.retired",
        "refs" => %{"sessionKey" => "other-session", "ownerUserId" => "other-user"},
        "payload" => %{"sessionKey" => "other-session", "ownerUserId" => "other-user"}
      })
    after
      :ok = :sys.resume(hub)
    end

    _barrier = Hub.sequence(hub, self())

    assert_receive {:subscriber_overflowed, ^affected_subscriber}, 5_000
    refute_received :firehose_overflow
    assert %{overflowed: false, queued: 0, seq: 0} = Hub.connection_stats(hub, self())

    Hub.publish(hub, %{
      "class" => "message.created",
      "refs" => %{
        "messageId" => "message-idle",
        "sessionKey" => "idle-session",
        "ownerUserId" => "flynn"
      },
      "payload" => %{
        "id" => "message-idle",
        "sessionKey" => "idle-session",
        "ownerUserId" => "flynn"
      }
    })

    _barrier = Hub.sequence(hub, self())
    assert_receive {:firehose_notice, %{"class" => "message.created", "seq" => 1}}, 5_000
    refute_received :firehose_overflow
  end

  defp register_subscriber!(hub, db, pid, session_key, id) do
    :ok =
      Hub.register(hub, pid, %{
        mode: :filtered,
        db: db,
        user_id: "flynn",
        principal_kind: :user,
        principal_id: "flynn",
        is_admin: true
      })

    :ok =
      Hub.subscribe(hub, pid, id, %{
        "classes" => ["message.created"],
        "sessionKey" => session_key
      })
  end
end
