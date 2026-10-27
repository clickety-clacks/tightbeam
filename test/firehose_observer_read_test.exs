defmodule Tightbeam.FirehoseObserverReadTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Firehose.Hub}

  test "credentialless observers receive subscribed revocation notices without revoking" do
    db = :firehose_observer_revocation_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    hub = start_supervised!({Hub, name: nil})

    :ok =
      Hub.register(hub, self(), %{
        mode: :filtered,
        db: db,
        user_id: nil,
        device_id: nil,
        principal_kind: :observer,
        principal_id: nil,
        is_admin: false
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
end
