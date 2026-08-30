defmodule Tightbeam.FirehoseSmokeTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.ClientE2E.WS

  alias Tightbeam.{ConditionFacts, Devices, Dispatch, Gateway, Harness, Org, Placement}
  alias Tightbeam.{Projection, ReadMarkers, StateResources, Wakes}
  alias Tightbeam.Firehose.{Hub, Publisher, Rebuild, Registry}
  alias Tightbeam.FirehoseAcceptanceFixture, as: Fixture

  @moduledoc """
  Firehose acceptance map: A1 and A3 are automated by the closed inventories,
  real source commits, filter matrix, and visibility-first probes in
  `Tightbeam.Firehose.RegistryProofTest`, with this real WebSocket journey as
  the representative public-boundary witness. A5 slow-consumer
  4008/reconnect/rebuild is automated here. `Tightbeam.FirehoseRestartSmokeTest`
  keeps that Card 1 journey in the normal suite and adds automated A5 gateway-kill
  recovery and A7 external-client restart proof on Linux and macOS CI.
  """

  test "authoritative production rebuild closes the current Registry both ways" do
    fixture = start_fixture!()
    :ok = Hub.register(fixture.hub, self())
    on_exit(fn -> Hub.unregister(fixture.hub, self()) end)

    {:ok, scheduler} =
      Supervisor.start_child(
        fixture.supervisor,
        {Wakes, db: fixture.db, name: nil, tick_ms: 60_000, deliver: fn _wake -> :ok end}
      )

    main = Tightbeam.TestCase.ensure_main_session(fixture.db, fixture.user_id)

    handlers =
      Gateway.handlers(%{
        db: fixture.db,
        base_dir: fixture.base_dir,
        wake_scheduler: scheduler,
        wake_tick_ms: 1_000
      })

    call = fn verb, params -> production_call(fixture, verb, params) end

    notices =
      capture_classes(fixture, %{}, ["config.updated"], fn ->
        handlers["config"].(
          call.("config", %{action: "set", setting: "default-priority", value: 7})
        )

        Hub.committed(
          fixture.hub,
          "config.updated",
          StateResources.query_config(fixture.db, "default-priority"),
          %{"key" => "default-priority"}
        )
      end)

    host = Placement.local_host_name()
    harness = hd(Harness.all()).wire_name()

    notices =
      capture_classes(fixture, notices, ["host_env.updated"], fn ->
        result =
          Placement.set_env_overlay_with_firehose(
            fixture.db,
            host,
            harness,
            "A4_COMPLETE",
            "private",
            "user:#{fixture.user_id}",
            call.("host-env-set", %{})
          )

        Hub.committed(
          fixture.hub,
          "host_env.updated",
          StateResources.query_host_environment(fixture.db, host, harness, "A4_COMPLETE"),
          %{}
        )

        result
      end)

    notices =
      capture_classes(fixture, notices, ["host.registered"], fn ->
        result =
          Placement.register_host_with_firehose(
            fixture.db,
            "a4-complete-host",
            %{ssh: nil, base_dir: "/a4/complete", cli_bin: nil, adapter_bin_dir: nil},
            call.("register-host", %{})
          )

        Hub.committed(
          fixture.hub,
          "host.registered",
          StateResources.query_host(fixture.db, "a4-complete-host"),
          %{"host" => "a4-complete-host"}
        )

        result
      end)

    notices =
      capture_classes(fixture, notices, ["user.added"], fn ->
        user = Devices.add_user(fixture.db, "a4-complete-user", false)

        Hub.committed(
          fixture.hub,
          "user.added",
          StateResources.query_user(fixture.db, user.user_id),
          %{"userId" => user.user_id}
        )
      end)

    Devices.add_user(fixture.db, "a4-promoted-user", false)

    notices =
      capture_classes(fixture, notices, ["user.promoted"], fn ->
        result =
          Devices.promote_user_with_firehose(
            fixture.db,
            "a4-promoted-user",
            call.("promote-user", %{user_id: "a4-promoted-user"})
          )

        Hub.committed(
          fixture.hub,
          "user.promoted",
          StateResources.query_user(fixture.db, "a4-promoted-user"),
          %{"userId" => "a4-promoted-user"}
        )

        result
      end)

    notices =
      Enum.reduce(
        [
          {"device.approved", "approve-device", "a4-approved", &Devices.approve_with_firehose/4},
          {"device.denied", "deny-device", "a4-denied", &Devices.deny_with_firehose/3},
          {"device.revoked", "revoke-device", "a4-revoked", &Devices.revoke_with_firehose/3}
        ],
        notices,
        fn {class, verb, device_id, mutation}, notices ->
          assert {:pending, _device} =
                   Devices.pair(fixture.db, %{
                     device_id: device_id,
                     claimed_name: device_id,
                     platform: nil,
                     model: nil
                   })

          capture_classes(fixture, notices, [class], fn ->
            case class do
              "device.approved" ->
                mutation.(
                  fixture.db,
                  device_id,
                  fixture.user_id,
                  call.("approve-device", %{device_id: device_id})
                )

              _ ->
                mutation.(fixture.db, device_id, call.(verb, %{device_id: device_id}))
            end
          end)
        end
      )

    notices =
      capture_classes(fixture, notices, ["read_marker.updated"], fn ->
        ReadMarkers.set(fixture.db, fixture.user_id, "a4-complete", "newer",
          firehose_call: call.("read-marker-set", %{scope_key: "a4-complete"})
        )
      end)

    notices =
      capture_classes(fixture, notices, ["critical_lease.updated"], fn ->
        Tightbeam.CriticalLeases.declare(
          fixture.db,
          main.session_key,
          1_000,
          "a4-complete",
          5_000,
          %{
            call.("critical", %{for_ms: 1_000, reason: "a4-complete"})
            | principal: {:session, main.session_key},
              session_key: main.session_key
          }
        )
      end)

    notices =
      capture_classes(fixture, notices, ["identity.updated", "kungfu.updated"], fn ->
        result =
          handlers["kungfu-scaffold"].(
            call.("kungfu-scaffold", %{
              name: "a4-complete",
              purpose: "Prove authoritative rebuild completeness."
            })
          )

        identity =
          fixture.db
          |> StateResources.query_identity(%{"name" => "served"})
          |> List.first()

        Hub.committed(fixture.hub, "identity.updated", identity, %{"name" => "served"})

        Hub.committed(
          fixture.hub,
          "kungfu.updated",
          StateResources.query_kungfu(fixture.db, "a4-complete"),
          %{"name" => "a4-complete"}
        )

        result
      end)

    dispatch_call =
      call.("dispatch", %{
        subject: "A4 production rebuild",
        brief: "Create real append-only rows."
      })
      |> Map.merge(%{session_key: main.session_key, target_role: nil, role_fallback: false})

    {:ok, assignment} = Dispatch.dispatch(fixture.db, handlers, dispatch_call)

    notices =
      capture_classes(fixture, notices, ["message.created"], fn ->
        {:appended, message} =
          Projection.append(fixture.db, %{
            session_key: main.session_key,
            role: "assistant",
            message_type: "substrate",
            content: "authoritative A4 message",
            sender: "process:tightbeam"
          })

        Hub.committed(fixture.hub, "message.created", message, %{
          "messageId" => message.id,
          "sessionKey" => main.session_key,
          "ownerUserId" => fixture.user_id
        })
      end)

    notices =
      capture_classes(fixture, notices, ["attest.filed"], fn ->
        {:ok, _result} =
          Dispatch.dispatch(fixture.db, handlers, %{
            call.("attest", %{
              assignment_id: assignment.id,
              kind: "progress",
              note: "authoritative A4 append"
            })
            | principal: {:session, main.session_key},
              origin: "agent:#{main.session_key}"
          })
      end)

    notices =
      capture_classes(fixture, notices, ["condition_fact.filed"], fn ->
        assert {%{kind: "a4-authoritative"}, true} =
                 ConditionFacts.file_idempotent_with_effect(
                   fixture.db,
                   scheduler,
                   %{
                     kind: "a4-authoritative",
                     scope: "complete",
                     origin: "user:#{fixture.user_id}",
                     idempotency_key: "a4-authoritative"
                   },
                   call.("condition", %{kind: "a4-authoritative", scope: "complete"})
                 )
      end)

    drain_publications(fixture)

    notices =
      capture_classes(fixture, notices, ["session.updated"], fn ->
        updated = Org.rename(fixture.db, main.session_key, "A4 authoritative rebuild")

        Hub.committed(fixture.hub, "session.updated", updated, %{
          "sessionKey" => main.session_key
        })
      end)

    registry_rebuildable =
      Registry.rows()
      |> Enum.flat_map(fn {class, row} -> if row[:rebuild], do: [class], else: [] end)
      |> Enum.sort()

    assert Map.keys(notices) |> Enum.sort() == Rebuild.classes()
    assert Rebuild.classes() == registry_rebuildable
    assert "session.updated" in Rebuild.classes()
    refute "prod.fired" in Rebuild.classes()
    assert "prod.fired" in Registry.observational_classes()
    assert Registry.fetch("prod.fired") == :error

    condition_notice = notices["condition_fact.filed"]
    assert condition_notice["refs"]["factId"] == condition_notice["payload"]["id"]
    refute Map.has_key?(condition_notice["payload"], "factId")

    catalog =
      %{
        {"testhost", "claude"} => [
          %{provider: :anthropic, family: "fable", efforts: [], context: nil}
        ]
      }
      |> Map.put_new(
        {host, harness},
        [
          %{
            provider: Harness.parse!(harness).credential_provider(),
            family: "unused",
            efforts: [],
            context: nil
          }
        ]
      )

    shape_failures =
      Enum.flat_map(notices, fn {class, notice} ->
        {:ok, row} = Registry.fetch(class)

        if StateResources.item_shape_complete?(row.resource, notice["payload"]) do
          []
        else
          [{class, row.resource, Map.keys(notice["payload"]) |> Enum.sort()}]
        end
      end)

    assert shape_failures == []

    for {class, notice} <- notices do
      assert {:ok, fresh} =
               Rebuild.fetch(fixture.db, class, notice["refs"], fixture.user_id, true)

      assert fresh == notice["payload"], class

      {:ok, row} = Registry.fetch(class)
      live_bytes = StateResources.encode_item(row.resource, notice["payload"], catalog)
      rebuilt_bytes = StateResources.encode_item(row.resource, fresh, catalog)

      assert rebuilt_bytes == live_bytes, class
      assert Publisher.encode_wire_notice(notice, catalog) =~ "\"payload\":" <> live_bytes
    end

    older = notices["read_marker.updated"]["payload"]

    latest =
      capture_classes(fixture, %{}, ["read_marker.updated"], fn ->
        ReadMarkers.set(fixture.db, fixture.user_id, "a4-complete", "latest",
          firehose_call: call.("read-marker-set", %{scope_key: "a4-complete"})
        )
      end)["read_marker.updated"]

    assert older["rowVersion"] < latest["payload"]["rowVersion"]

    assert {:ok, latest["payload"]} ==
             Rebuild.fetch(
               fixture.db,
               "read_marker.updated",
               latest["refs"],
               fixture.user_id,
               true
             )

    assert :forbidden ==
             Rebuild.fetch(
               fixture.db,
               "critical_lease.updated",
               notices["critical_lease.updated"]["refs"],
               fixture.user_id,
               false
             )

    assert {:ok, notices["host.registered"]["payload"]} ==
             Rebuild.fetch(
               fixture.db,
               "host.registered",
               notices["host.registered"]["refs"],
               fixture.user_id,
               false
             )

    assert :forbidden ==
             Rebuild.fetch(
               fixture.db,
               "user.promoted",
               notices["user.promoted"]["refs"],
               fixture.user_id,
               false
             )

    attacker = Devices.add_user(fixture.db, "a4-private-attacker", false)

    assert :forbidden ==
             Rebuild.fetch(
               fixture.db,
               "session.updated",
               notices["session.updated"]["refs"],
               attacker.user_id,
               false
             )

    victim = Devices.add_user(fixture.db, "a4-private-victim", false)
    ReadMarkers.set(fixture.db, victim.user_id, "private", "secret-marker")
    victim_refs = %{"userId" => victim.user_id, "scopeKey" => "private"}

    assert :forbidden ==
             Rebuild.fetch(
               fixture.db,
               "read_marker.updated",
               victim_refs,
               fixture.user_id,
               false
             )

    assert :forbidden ==
             Rebuild.fetch(
               fixture.db,
               "read_marker.updated",
               Map.put(victim_refs, "ownerUserId", fixture.user_id),
               fixture.user_id,
               false
             )

    assert :unsupported ==
             Rebuild.fetch(
               fixture.db,
               "work_item.updated",
               %{"workItemId" => assignment.workItemId},
               fixture.user_id,
               true
             )
  end

  test "external subscribe, query rebuild, live apply, and forced reconnect converge" do
    fixture = start_fixture!()
    ws = Fixture.connect(fixture)
    snapshot = Fixture.snapshot(fixture)
    assert snapshot == %{}

    first = Fixture.create_item(fixture, "First live item")
    {notice, ws} = Fixture.recv_change(ws)
    assert notice["class"] == "work_item.created"
    model = Map.put(snapshot, notice["refs"]["workItemId"], notice["payload"])
    assert Map.keys(model) == [first]

    assert Map.keys(model) |> Enum.sort() ==
             Fixture.snapshot(fixture) |> Map.keys() |> Enum.sort()

    :ok = WS.close(ws)
    second = Fixture.create_item(fixture, "Committed while disconnected")

    ws = Fixture.connect(fixture)
    rebuilt = Fixture.snapshot(fixture)
    assert Enum.sort(Map.keys(rebuilt)) == Enum.sort([first, second])

    third = Fixture.create_item(fixture, "After reconnect")
    {notice, ws} = Fixture.recv_change(ws)
    rebuilt = Map.put(rebuilt, notice["refs"]["workItemId"], notice["payload"])
    assert Enum.sort(Map.keys(rebuilt)) == Enum.sort([first, second, third])
    assert rebuilt == Fixture.snapshot(fixture)
    :ok = WS.close(ws)
  end

  test "a real slow consumer observes 4008 then reconnects, rebuilds, and converges" do
    owner = self()
    barrier_ref = make_ref()
    first_delivery = :atomics.new(1, signed: false)

    delivery_barrier = fn notice ->
      if :atomics.compare_exchange(first_delivery, 1, 0, 1) == :ok do
        send(owner, {:firehose_delivery_held, barrier_ref, self(), notice})

        receive do
          {:release_firehose_delivery, ^barrier_ref} -> :ok
        end
      end
    end

    fixture = start_fixture!(queue_limit: 2, delivery_barrier: delivery_barrier)
    ws = Fixture.connect(fixture)
    assert Fixture.snapshot(fixture) == %{}

    first = Fixture.create_item(fixture, "Held delivery")

    assert_receive {:firehose_delivery_held, ^barrier_ref, socket, first_notice}
    assert first_notice["refs"]["workItemId"] == first

    second = Fixture.create_item(fixture, "Queued delivery")
    third = Fixture.create_item(fixture, "Overflow delivery")

    publication_barrier(fixture)

    assert Hub.connection_stats(fixture.hub, socket) == %{
             in_flight: true,
             overflowed: true,
             queued: 0,
             seq: 3
           }

    send(socket, {:release_firehose_delivery, barrier_ref})
    assert {:ok, {:closed, 4008}, _ws} = Fixture.recv_close(ws, 2_000)

    ws = Fixture.connect(fixture)
    rebuilt = Fixture.snapshot(fixture)
    assert Enum.sort(Map.keys(rebuilt)) == Enum.sort([first, second, third])

    fourth = Fixture.create_item(fixture, "After slow-consumer reconnect")
    {notice, ws} = Fixture.recv_change(ws)
    rebuilt = Map.put(rebuilt, notice["refs"]["workItemId"], notice["payload"])
    assert Enum.sort(Map.keys(rebuilt)) == Enum.sort([first, second, third, fourth])
    assert rebuilt == Fixture.snapshot(fixture)
    :ok = WS.close(ws)
  end

  test "parallel fixtures own distinct state, ports, processes, and queues" do
    left = start_fixture!()
    right = start_fixture!()

    assert left.base_dir != right.base_dir
    assert left.db_path != right.db_path
    assert File.exists?(left.db_path)
    assert File.exists?(right.db_path)
    assert left.port != right.port
    assert left.db != right.db
    assert left.gateway != right.gateway
    assert left.hub != right.hub
    assert left.supervisor != right.supervisor

    left_task = Task.async(fn -> Fixture.create_item(left, "Left only") end)
    right_task = Task.async(fn -> Fixture.create_item(right, "Right only") end)
    left_id = Task.await(left_task)
    right_id = Task.await(right_task)

    assert Map.keys(Fixture.snapshot(left)) == [left_id]
    assert Map.keys(Fixture.snapshot(right)) == [right_id]

    assert :ok = Fixture.stop(left)
    assert :ok = Fixture.stop(right)
  end

  defp start_fixture!(opts \\ []) do
    fixture = Fixture.start!(opts)
    on_exit(fn -> assert :ok = Fixture.stop(fixture) end)
    fixture
  end

  defp firehose_call(verb, params) do
    %{
      verb: verb,
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: params,
      firehose_in_txn: true
    }
  end

  defp production_call(fixture, verb, params) do
    firehose_call(verb, params)
    |> Map.put(:firehose_hub, fixture.hub)
  end

  defp capture_classes(fixture, notices, classes, mutation) do
    _ = mutation.()
    wanted = MapSet.new(classes)
    receive_classes(fixture.hub, notices, wanted)
  end

  defp receive_classes(hub, notices, wanted) do
    if MapSet.size(wanted) == 0 do
      notices
    else
      receive do
        {:firehose_notice, %{"class" => class} = notice} ->
          Hub.delivered(hub, self())

          if MapSet.member?(wanted, class) do
            receive_classes(hub, Map.put(notices, class, notice), MapSet.delete(wanted, class))
          else
            receive_classes(hub, notices, wanted)
          end
      after
        2_000 ->
          flunk("missing authoritative Firehose classes: #{inspect(MapSet.to_list(wanted))}")
      end
    end
  end

  defp drain_publications(fixture) do
    marker = %{"fixtureBarrier" => inspect(make_ref())}

    assert {:ok, :ok} =
             Tightbeam.DB.transaction(fixture.db, fn txn ->
               Tightbeam.DB.Txn.handoff(txn, fixture.hub, {:publish, marker})
             end)

    receive_barrier(fixture.hub, marker)
  end

  defp publication_barrier(fixture) do
    marker = %{"fixtureBarrier" => inspect(make_ref())}
    :ok = Hub.register(fixture.hub, self())

    assert {:ok, :ok} =
             Tightbeam.DB.transaction(fixture.db, fn txn ->
               Tightbeam.DB.Txn.handoff(txn, fixture.hub, {:publish, marker})
             end)

    receive_barrier(fixture.hub, marker)
    Hub.unregister(fixture.hub, self())
  end

  defp receive_barrier(hub, marker) do
    receive do
      {:firehose_notice, ^marker} ->
        Hub.delivered(hub, self())
        :ok

      {:firehose_notice, _notice} ->
        Hub.delivered(hub, self())
        receive_barrier(hub, marker)
    after
      1_000 -> flunk("Firehose publication barrier was not delivered")
    end
  end
end
