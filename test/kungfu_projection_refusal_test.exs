defmodule Tightbeam.KungfuProjectionRefusalTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{AdminProjection, DB, Identity, StateResources, StateVisibility}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.{Hub, Publisher, Rebuild, Registry}
  alias Tightbeam.Wire.ChangeSocket
  @bytes "  SYNTHETIC_TOKEN=literal-secret\r\n/home/example/path\nλ\n\n"

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    hub = start_supervised!({Hub, name: Hub})
    :ok = AdminProjection.ensure_storage(db)
    :ok = DB.execute(db, "CREATE TABLE transport_rows(id INTEGER PRIMARY KEY)")
    %{db: db, hub: hub}
  end

  test "served stamp support preserves raw bytes and seed floors across rollback", %{db: db} do
    value = item() |> Map.delete("rowVersion")
    fingerprint = AdminProjection.fingerprint(value)
    assert byte_size(fingerprint) == 64

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               AdminProjection.seed_stamp_in_txn(
                 txn,
                 "kungfu",
                 "synthetic",
                 fingerprint,
                 value,
                 11
               )
             end)

    assert AdminProjection.stamped_item(db, "kungfu", "synthetic") ==
             Map.put(value, "rowVersion", 1)

    assert {:ok, true} =
             DB.transaction(
               db,
               &AdminProjection.fingerprint_matches?(&1, "kungfu", "synthetic", fingerprint)
             )

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               AdminProjection.seed_stamp_in_txn(txn, "kungfu", "synthetic", "different", %{}, 22)
             end)

    assert AdminProjection.stamped_item(db, "kungfu", "synthetic") ==
             Map.put(value, "rowVersion", 1)

    refute_receive {:firehose_notice, _}

    assert :ok =
             AdminProjection.record_fault(
               db,
               "kungfu",
               "synthetic",
               RuntimeError.exception("synthetic stamp failure")
             )

    assert {:ok, [["projection_stamp_failed"]]} =
             DB.query(db, "SELECT code FROM admin_projection_faults")

    assert {:error, %RuntimeError{message: "keep fault"}} =
             DB.transaction(db, fn txn ->
               :ok = AdminProjection.clear_fault_in_txn(txn, "kungfu", "synthetic")
               raise "keep fault"
             end)

    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM admin_projection_faults")

    assert {:ok, :ok} =
             DB.transaction(db, &AdminProjection.clear_fault_in_txn(&1, "kungfu", "synthetic"))

    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM admin_projection_faults")

    assert AdminProjection.stamped_item(db, "kungfu", "synthetic") ==
             Map.put(value, "rowVersion", 1)

    refute_receive {:firehose_notice, _}
  end

  test "identity publication validates references and records failed stamps without stale success",
       %{db: db, hub: hub} do
    register(hub)

    identity = %{
      "name" => "served",
      "liveRevision" => "synthetic-revision",
      "state" => "ready",
      "sessionRevisions" => %{},
      "staleness" => [],
      "conflicts" => []
    }

    value = %{
      resource: "identity",
      key: "served",
      class: "identity.updated",
      refs: %{"name" => "served"},
      item: identity
    }

    call = %{
      verb: "identity-edit",
      origin: "user:admin",
      principal: {:user, "admin"},
      params: %{},
      firehose_in_txn: true
    }

    assert {:ok, [first]} = AdminProjection.stamp_publication(db, call, [value])
    assert first["rowVersion"] == 1
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    assert_receive {:firehose_notice, %{"class" => "identity.updated", "payload" => ^first}}
    Hub.delivered(hub, self())
    assert {:ok, []} = AdminProjection.stamp_publication(db, call, [value])
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    refute_receive {:firehose_notice, _}

    assert_raise ArgumentError, fn ->
      AdminProjection.stamp_publication(db, call, [%{value | refs: %{"name" => "wrong"}}])
    end

    changed = %{value | item: Map.put(identity, "liveRevision", "next-revision")}

    assert {:error, %{code: "projection_stamp_failed"}} =
             AdminProjection.stamp_publication(db, call, [changed],
               before_stamp: fn _ -> raise "synthetic failure" end
             )

    assert AdminProjection.stamped_item(db, "identity", "served") == first
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM admin_projection_faults")
    refute_receive {:firehose_notice, _}
    assert {:ok, [next]} = AdminProjection.stamp_publication(db, call, [changed])
    assert next["rowVersion"] == 2
    assert next["liveRevision"] == "next-revision"
    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM admin_projection_faults")
  end

  defp item do
    %{
      "name" => "synthetic",
      "purpose" => "fixture",
      "phrases" => ["fixture"],
      "rootArchetype" => "coder",
      "installedRevision" => nil,
      "status" => "available",
      "documents" =>
        for(
          path <- ~w(README.md capabilities.md preferred-models.md),
          do: %{"path" => path, "content" => @bytes, "sha256" => sha(@bytes)}
        ),
      "rowVersion" => 1
    }
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp notice, do: Publisher.committed_notice("kungfu.updated", item(), %{})

  defp entry,
    do: %{resource: "kungfu", key: "synthetic", class: "kungfu.updated", refs: %{}, item: item()}

  defp register(hub, opts \\ %{}),
    do:
      Hub.register(hub, self(), Map.merge(%{mode: :all, user_id: "admin", is_admin: true}, opts))

  defp barrier(hub), do: :sys.get_state(hub)

  test "Identity serves only listed shipped files with exact content and SHA without base reads" do
    base = Path.join(System.tmp_dir!(), "absent-public-#{System.unique_integer([:positive])}")
    refute File.exists?(base)

    for name <- Identity.public_kungfu_names(base) do
      raw = Identity.public_kungfu(base, name)
      root = Application.app_dir(:tightbeam, "priv/kungfu/" <> name)

      expected =
        for path <- ~w(README.md capabilities.md preferred-models.md),
            File.regular?(Path.join(root, path)),
            do: path

      assert Enum.map(raw["documents"], & &1["path"]) == expected

      for doc <- raw["documents"] do
        bytes = File.read!(Path.join(root, doc["path"]))
        assert doc["content"] == bytes
        assert doc["sha256"] == sha(bytes)
      end

      assert raw == Identity.public_kungfu(base, name)
      assert StateResources.kungfu_snapshot(base, name) == raw
    end

    refute File.exists?(base)
    assert Identity.public_kungfu(base, "no-such-bundle") == nil
    assert_raise ArgumentError, fn -> Identity.public_kungfu(base, "../credentials") end
  end

  test "producer stamps bytes and publishes once; identical replay leaves the version", %{
    db: db,
    hub: hub
  } do
    :ok = register(hub)
    assert {:ok, [payload]} = AdminProjection.stamp_publication(db, %{}, [entry()])
    assert payload == item()
    barrier(hub)
    assert_receive {:firehose_notice, frame}
    assert frame == notice()
    assert {:ok, []} = AdminProjection.stamp_publication(db, %{}, [entry()])
    barrier(hub)
    refute_received {:firehose_notice, _}
    assert StateResources.query_kungfu(db, "synthetic") == item()

    assert Rebuild.fetch(db, "kungfu.updated", %{"name" => "synthetic"}, "admin", true) ==
             {:ok, item()}
  end

  test "stamp and actual Publisher roll back rows and handoffs atomically", %{db: db, hub: hub} do
    :ok = register(hub)

    assert {:error, %RuntimeError{message: "rollback"}} =
             DB.transaction(db, fn txn ->
               Txn.q(txn, "INSERT INTO transport_rows VALUES (1)")

               AdminProjection.allocate_in_txn(txn, "kungfu", "synthetic", 1,
                 item: JSON.encode!(item())
               )

               Publisher.committed_in_txn(txn, "kungfu.updated", item(), %{})
               raise "rollback"
             end)

    barrier(hub)
    refute_received {:firehose_notice, _}
    assert DB.query(db, "SELECT * FROM transport_rows") == {:ok, []}
    assert DB.query(db, "SELECT * FROM admin_projection_versions") == {:ok, []}

    assert {:error, %{code: "projection_stamp_failed"}} =
             AdminProjection.stamp_publication(db, %{}, [entry()],
               before_stamp: fn _ -> raise "stamp rollback" end
             )

    assert DB.query(db, "SELECT * FROM admin_projection_versions") == {:ok, []}
  end

  test "rebuild authorization precedes lookup and stamped bytes retain exact SHA", %{db: db} do
    assert :forbidden = Rebuild.fetch(:not_a_database, "kungfu.updated", %{}, "viewer", false)
    assert :forbidden = Rebuild.fetch(:not_a_database, "kungfu.updated", %{}, "", true)
    assert :unsupported = Rebuild.fetch(:not_a_database, "assignment.updated", %{}, "admin", true)
    assert {:ok, [_]} = AdminProjection.stamp_publication(db, %{}, [entry()])

    assert {:ok, payload} =
             Rebuild.fetch(db, "kungfu.updated", %{"name" => "synthetic"}, "admin", true)

    assert Enum.all?(
             payload["documents"],
             &(&1["content"] == @bytes and &1["sha256"] == sha(@bytes))
           )
  end

  test "closed shape and notice references reject malformed data without changing valid bytes" do
    assert "kungfu.updated" in Registry.classes()

    assert {:ok,
            %{
              resource: "kungfu",
              serializer: :kungfu,
              rebuild: true,
              primary_refs: ["name"],
              visibility: :kungfu_visible?
            }} =
             Registry.fetch("kungfu.updated")

    assert "kungfu.updated" in Rebuild.classes()
    assert Registry.fetch("assignment.updated") == :error
    assert StateVisibility.visible?(nil, notice(), "admin", true)
    refute StateVisibility.visible?(nil, notice(), "viewer", false)
    assert StateResources.kungfu(item()) == item()

    for bad <- [
          Map.put(item(), "extra", @bytes),
          Map.delete(item(), "documents"),
          Map.put(item(), "rowVersion", 0),
          Map.put(item(), "documents", [%{"path" => "x"}]),
          Map.put(item(), "documents", [
            %{"path" => "README.md", "content" => @bytes, "sha256" => "wrong"}
          ]),
          Map.put(item(), "documents", item()["documents"] ++ item()["documents"])
        ] do
      assert_raise ArgumentError, fn -> StateResources.kungfu(bad) end
    end

    for refs <- [%{"name" => "other"}, %{"ownerUserId" => "admin"}] do
      assert_raise ArgumentError, fn ->
        Publisher.committed_notice("kungfu.updated", item(), refs)
      end
    end

    assert JSON.decode!(Publisher.encode_wire_notice(notice())) == notice()
  end

  test "real committed transport reaches Hub after COMMIT with exact content", %{db: db, hub: hub} do
    :ok = register(hub)
    parent = self()

    assert {:ok, :written} =
             DB.transaction(db, fn txn ->
               Txn.q(txn, "INSERT INTO transport_rows VALUES (2)")
               Txn.handoff(txn, hub, {:publish, notice()})
               assert %{queued: 0, in_flight: false} = Hub.connection_stats(hub, parent)
               :written
             end)

    barrier(hub)
    assert_receive {:firehose_notice, frame}
    assert frame == notice()
    assert {:ok, [[2]]} = DB.query(db, "SELECT id FROM transport_rows")
  end

  test "admin subscription matching and sequence remain enforced", %{hub: hub} do
    :ok = register(hub, %{is_admin: false})
    Hub.publish(hub, notice())
    barrier(hub)
    refute_received {:firehose_notice, _}
    :ok = register(hub, %{mode: :subscribed})
    :ok = Hub.subscribe(hub, self(), "a", %{"classes" => ["kungfu."]})
    :ok = Hub.subscribe(hub, self(), "b", %{"classes" => ["assignment."]})
    Hub.publish(hub, notice())
    assert Hub.sequence(hub, self()) == 1
    assert_receive {:firehose_notice, frame}
    assert frame["payload"] == item()
    assert frame["subscriptionId"] == "a"
    assert frame["seq"] == 1
    Hub.delivered(hub, self())
    :ok = Hub.unsubscribe(hub, self(), "a")
    Hub.publish(hub, notice())
    barrier(hub)
    refute_received {:firehose_notice, _}
  end

  test "queued bytes retain content and authorization is rechecked at dequeue", %{hub: hub} do
    :ok = register(hub)
    Hub.publish(hub, notice())
    Hub.publish(hub, notice())
    assert %{queued: 1, in_flight: true} = Hub.connection_stats(hub, self())
    assert_receive {:firehose_notice, first}
    assert first == notice()
    :ok = register(hub, %{is_admin: false})
    Hub.delivered(hub, self())
    assert %{queued: 0, in_flight: false} = Hub.connection_stats(hub, self())
    refute_received {:firehose_notice, _}
  end

  test "changes route upgrades on loopback and delivers raw and general subscribed notices", %{
    db: db,
    hub: hub
  } do
    alias Tightbeam.ClientE2E.WS
    alias Tightbeam.Devices
    alias Tightbeam.Wire.Router
    :ok = Devices.ensure_schema(db)

    {:paired, device} =
      Devices.pair(db, %{
        device_id: "wire-synthetic",
        claimed_name: "Wire",
        platform: nil,
        model: nil
      })

    opts =
      Router.init(db: db, firehose_hub: hub, model_catalog: %{}, firehose_heartbeat_ms: 60_000)

    gateway =
      start_supervised!(
        {Bandit, plug: {Router, opts}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(gateway)
    assert {:ok, ws} = WS.connect("127.0.0.1", port, "/ws/changes?protocolVersion=1")

    try do
      :ok = WS.send_text(ws, JSON.encode!(%{"type" => "auth", "token" => device.token}))
      assert {:ok, {:text, auth}, ws} = WS.recv(ws, 2_000)
      assert JSON.decode!(auth)["success"] == true

      :ok =
        WS.send_text(
          ws,
          JSON.encode!(%{
            "type" => "subscribe",
            "protocolVersion" => 1,
            "subscriptionId" => "wire",
            "filters" => %{"classes" => ["kungfu.", "work_item."]}
          })
        )

      assert {:ok, {:text, ready}, ws} = WS.recv(ws, 2_000)
      assert JSON.decode!(ready)["type"] == "subscription_ready"

      Hub.publish(hub, notice())
      assert {:ok, {:text, bytes}, ws} = WS.recv(ws, 2_000)
      raw = JSON.decode!(bytes)
      assert raw["class"] == "kungfu.updated"
      assert raw["payload"] == notice()["payload"]
      assert raw["subscriptionId"] == "wire"
      assert raw["seq"] == 1

      general = %{
        "class" => "work_item.updated",
        "resource" => "work-items",
        "op" => "upsert",
        "occurredAt" => 1,
        "refs" => %{"workItemId" => "wi-wire", "ownerUserId" => device.user_id},
        "payload" => %{"id" => "wi-wire", "ownerUserId" => device.user_id, "rowVersion" => 1}
      }

      Hub.publish(hub, general)
      assert {:ok, {:text, bytes}, _ws} = WS.recv(ws, 2_000)
      frame = JSON.decode!(bytes)
      assert frame["payload"] == general["payload"]
      assert frame["class"] == "work_item.updated"
      assert frame["subscriptionId"] == "wire"
      assert frame["seq"] == 2
    after
      WS.close(ws)
    end
  end

  test "ChangeSocket authenticates synthetic devices and validates subscription state", %{
    db: db,
    hub: hub
  } do
    alias Tightbeam.Devices
    :ok = Devices.ensure_schema(db)

    pair = fn id ->
      Devices.pair(db, %{device_id: id, claimed_name: id, platform: nil, model: nil})
    end

    assert {:paired, admin} = pair.("synthetic-admin")
    assert {:pending, _} = pair.("synthetic-pending")
    deps = %{db: db, firehose_hub: hub, firehose_heartbeat_ms: 60_000, model_catalog: %{}}

    send_frame = fn state, message ->
      ChangeSocket.handle_in({JSON.encode!(message), opcode: :text}, state)
    end

    for {id, token, reason} <- [
          {"missing", "invalid", "auth_failed"},
          {"synthetic-pending", "invalid", "device_not_approved"}
        ] do
      assert {:ok, pending} = ChangeSocket.init(deps)

      assert {:stop, :normal, 1008, {:text, bytes}, ^pending} =
               send_frame.(pending, %{"type" => "auth", "deviceId" => id, "token" => token})

      assert JSON.decode!(bytes) == %{
               "type" => "auth_result",
               "success" => false,
               "reason" => reason
             }

      assert :ok = ChangeSocket.terminate(:normal, pending)
    end

    assert {:ok, pending} = ChangeSocket.init(deps)

    assert {:push, {:text, bytes}, live} =
             send_frame.(pending, %{"type" => "auth", "token" => admin.token})

    assert JSON.decode!(bytes) == %{
             "type" => "auth_result",
             "success" => true,
             "userId" => admin.user_id,
             "isAdmin" => true
           }

    assert live.phase == :live

    request = %{
      "type" => "subscribe",
      "protocolVersion" => 1,
      "subscriptionId" => "one",
      "filters" => %{"classes" => ["kungfu."]}
    }

    assert {:push, {:text, ready}, subscribed} = send_frame.(live, request)
    assert JSON.decode!(ready)["type"] == "subscription_ready"
    assert subscribed.subscriptions == %{"one" => %{"classes" => ["kungfu."]}}

    for invalid <- [
          request,
          %{request | "subscriptionId" => "two", "protocolVersion" => 2},
          %{request | "subscriptionId" => "two", "filters" => %{"unknown" => "value"}},
          %{request | "subscriptionId" => "two", "filters" => %{"classes" => [1]}}
        ] do
      assert {:push, {:text, refusal}, ^subscribed} = send_frame.(subscribed, invalid)
      assert JSON.decode!(refusal)["code"] == "invalid_request"
    end

    assert {:push, {:text, removed}, empty} =
             send_frame.(subscribed, %{"type" => "unsubscribe", "subscriptionId" => "one"})

    assert JSON.decode!(removed)["type"] == "subscription_removed"
    assert empty.subscriptions == %{}
    assert :ok = ChangeSocket.terminate(:normal, empty)

    assert :ok = Devices.revoke(db, admin.device_id)
    assert {:ok, pending} = ChangeSocket.init(deps)

    assert {:stop, :normal, 1008, {:text, revoked}, ^pending} =
             send_frame.(pending, %{
               "type" => "auth",
               "deviceId" => admin.device_id,
               "token" => admin.token
             })

    assert JSON.decode!(revoked)["reason"] == "token_revoked"
    assert :ok = ChangeSocket.terminate(:normal, pending)
  end

  test "final ChangeSocket preserves valid bytes and rejects unauthorized or malformed frames", %{
    hub: hub
  } do
    :ok = register(hub)

    state = %ChangeSocket{
      phase: :live,
      user_id: "admin",
      is_admin: true,
      deps: %{firehose_hub: hub}
    }

    assert {:push, {:text, bytes}, ^state} =
             ChangeSocket.handle_info({:firehose_notice, notice()}, state)

    assert JSON.decode!(bytes) == notice()

    assert {:stop, :normal, 1008, ^state} =
             ChangeSocket.handle_info(
               {:firehose_notice, Map.put(notice(), "message", @bytes)},
               state
             )

    denied = %{state | user_id: "viewer", is_admin: false}

    assert {:stop, :normal, 1008, ^denied} =
             ChangeSocket.handle_info({:firehose_notice, notice()}, denied)

    pending = %{denied | phase: :unauthed}
    assert {:ok, ^pending} = ChangeSocket.handle_info({:firehose_notice, notice()}, pending)

    assert {:stop, :normal, 1008, {:text, refusal}, ^pending} =
             ChangeSocket.handle_in({"{}", opcode: :text}, pending)

    assert JSON.decode!(refusal) == %{
             "type" => "auth_result",
             "success" => false,
             "reason" => "auth_failed"
           }
  end

  test "queue overflow and owned process cleanup remain bounded", %{hub: hub} do
    small = start_supervised!({Hub, name: nil, queue_limit: 1}, id: :small)
    :ok = register(small)
    Hub.publish(small, notice())
    Hub.publish(small, notice())
    assert %{queued: 0, overflowed: true} = Hub.connection_stats(small, self())
    assert_receive {:firehose_notice, frame}
    assert frame == notice()
    assert_receive :firehose_overflow

    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(pid)
    :ok = Hub.register(hub, pid, %{mode: :pending})
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert :ok = Hub.shutdown(hub)
    assert Hub.connection_stats(hub, pid) == nil
  end
end
