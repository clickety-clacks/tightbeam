defmodule Tightbeam.Wire.ChangeSocketTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Gateway}
  alias Tightbeam.Firehose.{Hub, Registry}
  alias Tightbeam.Wire.ChangeSocket

  setup do
    db = :"change_socket_db_#{System.unique_integer([:positive])}"
    hub = :"change_socket_hub_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({Hub, name: hub})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:paired, device} =
      claim_org(db, %{device_id: "d1", claimed_name: "Flynn", platform: nil, model: nil})

    {:ok, state} =
      ChangeSocket.init(%{db: db, firehose_hub: hub, firehose_heartbeat_ms: 60_000})

    %{db: db, hub: hub, device: device, state: state}
  end

  test "auth is in-band and subscriptions are multiplexed with conjunctive filters", ctx do
    {:push, {:text, auth_bytes}, state} =
      inbound(%{"type" => "auth", "token" => ctx.device.token}, ctx.state)

    assert %{"type" => "auth_result", "success" => true, "userId" => "flynn"} =
             JSON.decode!(auth_bytes)

    {:push, {:text, _ready}, state} =
      inbound(
        %{
          "type" => "subscribe",
          "protocolVersion" => 1,
          "subscriptionId" => "work",
          "filters" => %{"classes" => ["work_item."], "workItemId" => "wi_1"}
        },
        state
      )

    {:push, {:text, _ready}, state} =
      inbound(
        %{
          "type" => "subscribe",
          "protocolVersion" => 1,
          "subscriptionId" => "all-work",
          "filters" => %{"classes" => ["work_item."]}
        },
        state
      )

    notice = %{
      "class" => "work_item.updated",
      "resource" => "work-items",
      "op" => "upsert",
      "occurredAt" => 1,
      "refs" => %{"workItemId" => "wi_1", "ownerUserId" => "flynn"},
      "payload" => %{"id" => "wi_1", "ownerUserId" => "flynn", "rowVersion" => 1}
    }

    Hub.publish(ctx.hub, notice)

    decoded =
      Enum.map(1..2, fn _ ->
        assert_receive {:firehose_notice, frame}

        assert {:push, {:text, bytes}, ^state} =
                 ChangeSocket.handle_info({:firehose_notice, frame}, state)

        JSON.decode!(bytes)
      end)

    assert Enum.map(decoded, & &1["subscriptionId"]) |> Enum.sort() == ["all-work", "work"]
    assert Enum.map(decoded, & &1["seq"]) |> Enum.sort() == [1, 2]
  end

  test "the 101st subscription is a typed invalid_request", ctx do
    {:push, {:text, _auth}, state} =
      inbound(%{"type" => "auth", "token" => ctx.device.token}, ctx.state)

    state =
      Enum.reduce(1..100, state, fn index, state ->
        {:push, {:text, _ready}, state} =
          inbound(
            %{
              "type" => "subscribe",
              "protocolVersion" => 1,
              "subscriptionId" => "s#{index}"
            },
            state
          )

        state
      end)

    {:push, {:text, error}, _state} =
      inbound(
        %{"type" => "subscribe", "protocolVersion" => 1, "subscriptionId" => "s101"},
        state
      )

    assert %{"type" => "error", "code" => "invalid_request", "message" => message} =
             JSON.decode!(error)

    assert message =~ "100"
  end

  test "heartbeat carries the latest connection sequence", ctx do
    {:push, {:text, _auth}, state} =
      inbound(%{"type" => "auth", "token" => ctx.device.token}, ctx.state)

    {:push, {:text, _ready}, state} =
      inbound(
        %{"type" => "subscribe", "protocolVersion" => 1, "subscriptionId" => "all"},
        state
      )

    Hub.publish(ctx.hub, notice("wi_trailing"))
    assert_receive {:firehose_notice, _suppressed_delivery}

    assert {:push, {:text, bytes}, _state} = ChangeSocket.handle_info(:firehose_heartbeat, state)
    assert JSON.decode!(bytes) == %{"type" => "heartbeat", "seq" => 1}
  end

  test "a retirement affecting the authenticated owner closes with policy code", ctx do
    {:push, {:text, _auth}, state} =
      inbound(%{"type" => "auth", "token" => ctx.device.token}, ctx.state)

    retirement = %{
      "class" => "session.retired",
      "refs" => %{"sessionKey" => "agent:worker"},
      "payload" => %{"sessionKey" => "agent:worker", "ownerUserId" => "flynn"}
    }

    Hub.publish(ctx.hub, retirement)
    assert_receive :firehose_revoked

    assert {:stop, :normal, 1008, ^state} =
             ChangeSocket.handle_info(:firehose_revoked, state)
  end

  test "publication before the registration cut is never delivered", ctx do
    {:push, {:text, _auth}, _state} =
      inbound(%{"type" => "auth", "token" => ctx.device.token}, ctx.state)

    socket = self()
    :ok = :sys.suspend(ctx.hub)
    Hub.publish(ctx.hub, notice("wi_before"))
    subscribe = Task.async(fn -> Hub.subscribe(ctx.hub, socket, "work", %{}) end)
    :ok = :sys.resume(ctx.hub)
    assert :ok = Task.await(subscribe)
    refute_receive {:firehose_notice, _notice}, 50

    Hub.publish(ctx.hub, notice("wi_after"))
    assert_receive {:firehose_notice, %{"refs" => %{"workItemId" => "wi_after"}, "seq" => 1}}
  end

  test "the per-connection queue is exact and overflow closes once", ctx do
    {:push, {:text, _auth}, _state} =
      inbound(%{"type" => "auth", "token" => ctx.device.token}, ctx.state)

    :ok = Hub.subscribe(ctx.hub, self(), "work", %{})

    Enum.each(1..1_500, fn index -> Hub.publish(ctx.hub, notice("wi_#{index}")) end)

    assert %{in_flight: true, overflowed: true, queued: 0, seq: 1_001} =
             Hub.connection_stats(ctx.hub, self())

    assert_receive {:firehose_notice, %{"seq" => 1}}
    assert_receive :firehose_overflow
    refute_receive :firehose_overflow, 50
    refute_receive {:firehose_notice, _notice}, 50
  end

  test "gateway shutdown closes change sockets with restarting code", ctx do
    {:push, {:text, _auth}, state} =
      inbound(%{"type" => "auth", "token" => ctx.device.token}, ctx.state)

    shutdown = Task.async(fn -> Hub.shutdown(ctx.hub) end)
    assert_receive :firehose_shutdown
    refute Task.yield(shutdown, 0)
    assert {:stop, :normal, 1012, ^state} = ChangeSocket.handle_info(:firehose_shutdown, state)
    assert :ok = Task.await(shutdown)
  end

  test "gateway shutdown closes an upgraded pre-auth socket with restarting code", ctx do
    state = ctx.state
    shutdown = Task.async(fn -> Hub.shutdown(ctx.hub) end)
    assert_receive :firehose_shutdown
    refute Task.yield(shutdown, 0)

    assert {:stop, :normal, 1012, ^state} =
             ChangeSocket.handle_info(:firehose_shutdown, state)

    assert :ok = Task.await(shutdown)
  end

  test "registry rows are both-way unique and cover effects from the real gateway table", ctx do
    rows = Registry.rows()
    config = %{db: ctx.db}
    handlers = Gateway.handlers(config)
    handler_effects = Gateway.handler_effects(config)
    {:module, Tightbeam.StateResources} = Code.ensure_loaded(Tightbeam.StateResources)

    assert map_size(rows) ==
             rows |> Map.values() |> Enum.map(& &1.class) |> Enum.uniq() |> length()

    assert Enum.all?(rows, fn {class, row} ->
             class == row.class and row.op in ~w(upsert delete) and
               function_exported?(Tightbeam.StateResources, row.serializer, 1)
           end)

    assert Enum.all?(Registry.observational_classes(), &match?(:error, Registry.fetch(&1)))
    assert Enum.sort(Map.keys(rows) ++ Registry.observational_classes()) == Registry.classes()
    assert Map.keys(handlers) |> Enum.sort() == Map.keys(handler_effects) |> Enum.sort()
    assert_registry_match!(handler_effects, rows)

    assert_raise ArgumentError, ~r/every executable handler must bind/, fn ->
      Gateway.compile_handler_specs!(%{"unclassified-mutator" => fn _call -> %{} end})
    end

    assert_raise ArgumentError,
                 ~r/registry mismatch.*extra classes=\["critical_lease.updated"\]/,
                 fn ->
                   assert_registry_match!(
                     handler_effects,
                     Map.delete(rows, "critical_lease.updated")
                   )
                 end

    extra_row = %{class: "unregistered.extra", op: "upsert", serializer: :work_item}

    assert_raise ArgumentError,
                 ~r/registry mismatch.*missing classes=\["unregistered.extra"\]/,
                 fn ->
                   assert_registry_match!(
                     handler_effects,
                     Map.put(rows, "unregistered.extra", extra_row)
                   )
                 end

    expected_admin_rows = %{
      "config.updated" => {"config", ["key"], :query_config, :config, :config_visible?},
      "host_env.updated" =>
        {"host environment", ["host", "harness", "name"], :query_host_environment,
         :host_environment, :host_environment_visible?},
      "identity.updated" =>
        {"identity", ["name"], :query_identity, :identity, :identity_visible?},
      "host.registered" => {"hosts", ["host"], :query_host, :host, :host_visible?},
      "kungfu.updated" => {"kungfu", ["name"], :query_kungfu, :kungfu, :kungfu_visible?},
      "user.promoted" => {"users", ["userId"], :query_user, :user, :user_visible?}
    }

    assert Map.new(expected_admin_rows, fn {class, expected} ->
             row = Map.fetch!(rows, class)

             actual =
               {row.resource, row.primary_refs, row.query, row.serializer, row.visibility}

             assert actual == expected
             {class, actual}
           end) == expected_admin_rows
  end

  test "condition facts share owner visibility and critical state is admin-only", ctx do
    fact = %{
      "class" => "condition_fact.filed",
      "refs" => %{"principal" => "user:flynn"},
      "payload" => %{"factId" => 1, "origin" => "user:flynn"}
    }

    assert Tightbeam.StateVisibility.visible?(ctx.db, fact, "flynn", false)
    refute Tightbeam.StateVisibility.visible?(ctx.db, fact, "other", false)

    critical = %{
      "class" => "critical_lease.updated",
      "refs" => %{"sessionKey" => "agent:worker"},
      "payload" => %{"sessionKey" => "agent:worker"}
    }

    assert Tightbeam.StateVisibility.visible?(ctx.db, critical, "flynn", true)
    refute Tightbeam.StateVisibility.visible?(ctx.db, critical, "flynn", false)
  end

  defp inbound(payload, state),
    do: ChangeSocket.handle_in({JSON.encode!(payload), opcode: :text}, state)

  defp assert_registry_match!(handler_effects, rows) do
    declared = Gateway.emitted_state_classes(handler_effects)
    registered = rows |> Map.keys() |> Enum.sort()
    extra = declared -- registered
    missing = registered -- declared

    if extra != [] or missing != [] do
      raise ArgumentError,
            "firehose registry mismatch: extra classes=#{inspect(extra)} " <>
              "missing classes=#{inspect(missing)}"
    end

    :ok
  end

  defp notice(id) do
    %{
      "class" => "work_item.updated",
      "resource" => "work-items",
      "op" => "upsert",
      "occurredAt" => 1,
      "refs" => %{"workItemId" => id, "ownerUserId" => "flynn"},
      "payload" => %{"id" => id, "ownerUserId" => "flynn", "rowVersion" => 1}
    }
  end
end
