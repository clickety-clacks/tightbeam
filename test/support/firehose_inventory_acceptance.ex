defmodule Tightbeam.FirehoseInventoryAcceptance do
  @moduledoc false
  import ExUnit.Assertions
  alias Tightbeam.ClientE2E.WS
  alias Tightbeam.{ConditionFacts, Devices, Dispatch, Gateway, Harness, Org, Placement}
  alias Tightbeam.{Projection, ReadMarkers, StateResources, SubagentMarkers, Toplines, Wakes}
  alias Tightbeam.Firehose.{Hub, Rebuild, Registry}
  alias Tightbeam.FirehoseAcceptanceFixture, as: Fixture
  @a4_replay_seed {7_913, 10_007, 65_537}
  @a4_r8b_classes Registry.invalidation_rows() |> Map.keys() |> Enum.sort()
  @a4_delete_classes ~w(role.created role.removed)

  def run!(fixture) do
    :ok = Toplines.ensure_schema(fixture.db)

    main =
      Org.create(fixture.db, %{
        session_key: "a4-inventory-main",
        owner_user_id: fixture.user_id,
        origin: "user:#{fixture.user_id}",
        display_name: "A4 inventory",
        archetype: "default",
        harness: "fixture",
        provider: "fixture_provider",
        model: Tightbeam.Model.new("fixture-model"),
        host: "testhost"
      })

    # Publish the first real served revision before subscriptions exist.
    setup_handlers = Gateway.handlers(%{db: fixture.db, base_dir: fixture.base_dir})

    setup_handlers["kungfu-scaffold"].(
      production_call(fixture, "kungfu-scaffold", %{
        name: "a4-complete",
        purpose: "Prove authoritative rebuild completeness."
      })
    )

    first_kungfu = StateResources.query_kungfu(fixture.db, "a4-complete")
    assert first_kungfu["rowVersion"] > 0

    ws =
      Fixture.connect(fixture,
        subscription_id: "a4-authoritative",
        filters: %{"classes" => Rebuild.classes() ++ @a4_r8b_classes ++ @a4_delete_classes}
      )

    :ok =
      Hub.register(fixture.hub, self(), %{
        mode: :all,
        db: fixture.db,
        user_id: fixture.user_id,
        is_admin: true
      })

    {:ok, scheduler} =
      Supervisor.start_child(
        fixture.supervisor,
        {Wakes, db: fixture.db, name: nil, tick_ms: 60_000, deliver: fn _wake -> :ok end}
      )

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

        result
      end)

    notices =
      capture_classes(fixture, notices, ["host.registered"], fn ->
        result =
          Placement.register_host_with_firehose(
            fixture.db,
            "a4-complete-host",
            %{
              ssh: nil,
              base_dir: Path.join(fixture.base_dir, "synthetic-host"),
              cli_bin: nil,
              adapter_bin_dir: nil
            },
            call.("register-host", %{})
          )

        result
      end)

    notices =
      capture_classes(fixture, notices, ["user.added"], fn ->
        Devices.add_user_with_firehose(
          fixture.db,
          "a4-complete-user",
          false,
          call.("add-user", %{user_id: "a4-complete-user"})
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

        result
      end)

    Devices.add_user(fixture.db, "a4-demoted-user", true)

    notices =
      capture_classes(fixture, notices, ["user.demoted"], fn ->
        Devices.promote_user_with_firehose(
          fixture.db,
          "a4-demoted-user",
          false,
          call.("promote-user", %{user_id: "a4-demoted-user", is_admin: false})
        )
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
        guidance =
          fixture.base_dir
          |> Path.join("identity")
          |> Path.join("guidance/a4-complete-role.md")
          |> File.read!()

        result =
          handlers["identity-edit"].(
            call.("identity-edit", %{
              archetype: "a4-complete-role",
              content: guidance <> "\n<!-- Synthetic inventory revision. -->\n"
            })
          )

        identity = StateResources.query_identity(fixture.db, "served")

        result
      end)

    assert notices["kungfu.updated"]["payload"]["rowVersion"] >
             first_kungfu["rowVersion"]

    assert_raise ArgumentError, fn ->
      notices["kungfu.updated"]["payload"]
      |> Map.put("rowVersion", 0)
      |> StateResources.kungfu()
    end

    dispatch_call =
      call.("assign", %{subject: "A4 production rebuild"})
      |> Map.merge(%{session_key: main.session_key, target_role: nil, role_fallback: false})

    {:ok, assignment} = Dispatch.dispatch(fixture.db, handlers, dispatch_call)

    notices =
      capture_classes(fixture, notices, ["message.created"], fn ->
        {:ok, _} =
          Tightbeam.DB.transaction(fixture.db, fn txn ->
            {:appended, message} =
              Projection.append_in_txn(txn, %{
                session_key: main.session_key,
                role: "assistant",
                message_type: "substrate",
                content: "authoritative A4 message",
                sender: "process:tightbeam"
              })

            Tightbeam.Firehose.Publisher.committed_in_txn(txn, "message.created", message, %{
              "messageId" => message.id,
              "sessionKey" => main.session_key,
              "ownerUserId" => fixture.user_id
            })
          end)
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

    for {class, notice} <- notices do
      assert {:ok, fresh} =
               Rebuild.fetch(fixture.db, class, notice["refs"], fixture.user_id, true)

      assert fresh == notice["payload"],
             "#{class}: fresh=#{inspect(fresh)} delivered=#{inspect(notice["payload"])}"
    end

    :ok = Hub.unregister(fixture.hub, self())
    ws = assert_a4_websocket_convergence(fixture, ws, notices)

    :ok =
      Hub.register(fixture.hub, self(), %{
        mode: :all,
        db: fixture.db,
        user_id: fixture.user_id,
        is_admin: true
      })

    r8b_work_item = Fixture.create_item(fixture, "A4 observe refetch work item")

    {:ok, r8b_assignment} =
      Dispatch.dispatch(
        fixture.db,
        handlers,
        call.("assign", %{subject: "A4 observe refetch", work_item_id: r8b_work_item})
        |> Map.merge(%{session_key: main.session_key, target_role: nil, role_fallback: false})
      )

    r8b_notices = a4_r8b_notices(fixture, main, r8b_assignment, r8b_work_item, scheduler, call)
    ws = assert_a4_observe_refetch(fixture, ws, r8b_notices)

    ws = assert_a4_delete_recreate(fixture, ws, handlers, call)
    :ok = WS.close(ws)

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

  # The frames begin as real committed production projections. The altered
  # version is an adversarial transport replay: it must leave the client model
  # at the same fresh authoritative state as the duplicate does.
  defp assert_a4_websocket_convergence(fixture, ws, notices) do
    {model, ws} =
      Enum.reduce(1..map_size(notices), {%{}, ws}, fn _, {model, ws} ->
        {notice, ws} = Fixture.recv_change(ws)
        fresh = assert_a4_fresh!(fixture, notice)
        model = apply_a4_notice(model, notice)
        assert model[a4_key(notice)].payload == fresh
        assert model[a4_key(notice)].applications == 1
        {model, ws}
      end)

    {model, ws} = replay_a4_orders(fixture, ws, model, notices)

    assert map_size(model) == map_size(notices)
    ws
  end

  defp assert_a4_fresh!(fixture, notice) do
    assert {:ok, fresh} =
             Rebuild.fetch(
               fixture.db,
               notice["class"],
               notice["refs"],
               fixture.user_id,
               true
             )

    fresh
  end

  defp apply_a4_notice(model, notice) do
    key = a4_key(notice)
    version = notice["payload"]["rowVersion"] || notice["occurredAt"]

    case {notice["op"], model} do
      {"delete", _} ->
        Map.delete(model, key)

      {_, %{^key => %{version: current}}} when current >= version ->
        model

      {_, %{^key => current}} ->
        Map.put(model, key, %{
          version: version,
          payload: notice["payload"],
          applications: current.applications + 1
        })

      _ ->
        Map.put(model, key, %{version: version, payload: notice["payload"], applications: 1})
    end
  end

  defp a4_key(notice) do
    {:ok, row} = Registry.fetch(notice["class"])
    {row.resource, Map.take(notice["refs"], row.primary_refs)}
  end

  defp canonical_notice(notice),
    do: Map.take(notice, ["class", "occurredAt", "op", "payload", "refs", "resource"])

  defp replay_a4_orders(fixture, ws, model, notices) do
    random = :rand.seed_s(:exsplus, @a4_replay_seed)

    {replays, _random} =
      notices
      |> Enum.sort_by(fn {class, _notice} -> class end)
      |> Enum.map_reduce(random, fn {_class, notice}, random ->
        {choice, random} = :rand.uniform_s(2, random)
        order = if choice == 1, do: [:duplicate, :older], else: [:older, :duplicate]
        {{notice, order}, random}
      end)

    Enum.reduce(replays, {model, ws}, fn {notice, order}, {model, ws} ->
      older = put_in(notice, ["payload", "rowVersion"], notice["payload"]["rowVersion"] - 1)

      Enum.reduce(order, {model, ws}, fn replay, {model, ws} ->
        outbound = if replay == :duplicate, do: notice, else: older
        :ok = Hub.publish(fixture.hub, outbound)
        {received, ws} = Fixture.recv_change(ws)
        assert canonical_notice(received) == outbound
        fresh = assert_a4_fresh!(fixture, received)
        applications = model[a4_key(received)].applications
        model = apply_a4_notice(model, received)
        assert model[a4_key(received)].payload == fresh
        assert model[a4_key(received)].applications == applications
        {model, ws}
      end)
    end)
  end

  # R8b notices carry only a source version and refs. A client must request a
  # refetch; it must not put the invalidation in its projection model.
  defp assert_a4_observe_refetch(fixture, ws, notices) do
    {refetches, ws} =
      Enum.reduce(1..map_size(notices), {[], ws}, fn _, {refetches, ws} ->
        {notice, ws} = Fixture.recv_change(ws)
        expected = Map.fetch!(notices, notice["class"])

        assert canonical_notice(notice) == expected
        assert notice["op"] == "observe"
        assert :error == Registry.fetch(notice["class"])

        assert :unsupported ==
                 Rebuild.fetch(fixture.db, notice["class"], notice["refs"], fixture.user_id, true)

        {%{effect: :refetch, class: class, refs: refs, source_version: source_version} = refetch,
         _model} = apply_a4_observe(%{}, notice)

        assert refetch == %{
                 effect: :refetch,
                 class: notice["class"],
                 refs: notice["refs"],
                 source_version: notice["payload"]["sourceVersion"]
               }

        assert is_binary(class)
        assert is_map(refs)
        assert is_integer(source_version)
        {[refetch | refetches], ws}
      end)

    assert Enum.sort_by(refetches, & &1.class) ==
             notices
             |> Map.values()
             |> Enum.map(fn notice ->
               %{
                 effect: :refetch,
                 class: notice["class"],
                 refs: notice["refs"],
                 source_version: notice["payload"]["sourceVersion"]
               }
             end)
             |> Enum.sort_by(& &1.class)

    ws
  end

  defp apply_a4_observe(model, notice) do
    %{
      "class" => class,
      "op" => "observe",
      "payload" => %{"sourceVersion" => version},
      "refs" => refs
    } =
      notice

    {%{effect: :refetch, class: class, refs: refs, source_version: version}, model}
  end

  defp a4_r8b_notices(fixture, main, assignment, work_item_id, scheduler, call) do
    capture_classes(fixture, %{}, @a4_r8b_classes, fn ->
      created =
        Toplines.create(
          fixture.db,
          call.("topline-create", %{title: "A4 observe refetch", idempotency_key: "a4-r8b-create"})
        )

      linked =
        Toplines.link_work(
          fixture.db,
          call.("topline-link-work", %{
            topline_id: created.topline.id,
            work_item_id: work_item_id,
            reason: "A4 observe refetch",
            idempotency_key: "a4-r8b-link"
          })
        )

      assert %{membership: _} = linked

      _unlinked =
        Toplines.unlink_work(
          fixture.db,
          call.("topline-unlink-work", %{
            membership_id: linked.membership.id,
            reason: "A4 observe refetch complete",
            idempotency_key: "a4-r8b-unlink"
          })
        )

      assert %{appended: true} =
               SubagentMarkers.append(fixture.db, scheduler, %{
                 kind: "subagent_start",
                 principal: main.session_key,
                 subagent_ref: "subagent:a4-r8b",
                 source_event_ref: "a4-r8b-marker",
                 harness: :codex,
                 at: 7_500,
                 assignment_id: assignment.id,
                 firehose_hub: fixture.hub
               })
    end)
  end

  defp assert_a4_delete_recreate(fixture, ws, handlers, call) do
    role = "a4-delete-recreate"

    {model, ws} =
      a4_role_delivery(fixture, ws, %{}, "role.created", fn ->
        assert {:ok, %{role: %{name: ^role}}} =
                 Dispatch.dispatch(
                   fixture.db,
                   handlers,
                   call.("role-create", %{name: role, bind: nil})
                 )
      end)

    {model, ws} =
      a4_role_delivery(fixture, ws, model, "role.removed", fn ->
        assert {:ok, %{removed: ^role}} =
                 Dispatch.dispatch(fixture.db, handlers, call.("role-rm", %{name: role}))
      end)

    {model, ws} =
      a4_role_delivery(fixture, ws, model, "role.created", fn ->
        assert {:ok, %{role: %{name: ^role}}} =
                 Dispatch.dispatch(
                   fixture.db,
                   handlers,
                   call.("role-create", %{name: role, bind: nil})
                 )
      end)

    assert map_size(model) == 1
    ws
  end

  defp a4_role_delivery(fixture, ws, model, class, mutation) do
    expected = capture_classes(fixture, %{}, [class], mutation)[class]
    {notice, ws} = Fixture.recv_change(ws)
    assert canonical_notice(notice) == expected
    model = apply_a4_notice(model, notice)
    key = a4_key(notice)

    case notice["op"] do
      "delete" ->
        refute Map.has_key?(model, key)
        assert nil == StateResources.query_role(fixture.db, notice["refs"]["role"])

      "upsert" ->
        fresh =
          fixture.db
          |> StateResources.query_role(notice["refs"]["role"])
          |> StateResources.role()

        assert model[key].payload == fresh
        assert model[key].applications == 1
    end

    {model, ws}
  end

  defp firehose_call(fixture, verb, params) do
    %{
      verb: verb,
      origin: "user:#{fixture.user_id}",
      principal: {:user, fixture.user_id},
      session_key: nil,
      params: params,
      firehose_in_txn: true
    }
  end

  defp production_call(fixture, verb, params) do
    firehose_call(fixture, verb, params)
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
    observer = self()
    # DB sends its committed outbox before this callback. A call from that
    # same sender establishes the boundary without injecting a fake notice.
    assert {:ok, _} =
             Tightbeam.DB.transaction_then(fixture.db, fn _ -> :ok end, fn _ ->
               Hub.sequence(fixture.hub, observer)
             end)

    Hub.sequence(fixture.hub, observer)
    drain_observer(fixture.hub)
  end

  defp drain_observer(hub) do
    case Hub.connection_stats(hub, self()) do
      %{in_flight: false, queued: 0} ->
        :ok

      _ ->
        receive do
          {:firehose_notice, _} ->
            Hub.delivered(hub, self())
            drain_observer(hub)
        after
          2_000 -> flunk("real committed observer queue did not drain")
        end
    end
  end
end
