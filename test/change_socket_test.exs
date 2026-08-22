defmodule Tightbeam.Wire.ChangeSocketTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Devices, Gateway}
  alias Tightbeam.Firehose.{Hub, Registry}
  alias Tightbeam.Wire.ChangeSocket

  setup do
    db = :"change_socket_db_#{System.unique_integer([:positive])}"
    hub = :"change_socket_hub_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({Hub, name: hub})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:paired, device} =
      Devices.pair(db, %{device_id: "d1", claimed_name: "Flynn", platform: nil, model: nil})

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

    assert {:push, frames, state} = ChangeSocket.handle_info({:firehose_notice, notice}, state)
    decoded = Enum.map(frames, fn {:text, bytes} -> JSON.decode!(bytes) end)

    assert Enum.map(decoded, & &1["subscriptionId"]) |> Enum.sort() == ["all-work", "work"]
    assert Enum.map(decoded, & &1["seq"]) |> Enum.sort() == [1, 2]
    assert state.seq == 2
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

    state = %{state | seq: 7}
    assert {:push, {:text, bytes}, _state} = ChangeSocket.handle_info(:firehose_heartbeat, state)
    assert JSON.decode!(bytes) == %{"type" => "heartbeat", "seq" => 7}
  end

  test "a retirement affecting the authenticated owner closes with policy code", ctx do
    {:push, {:text, _auth}, state} =
      inbound(%{"type" => "auth", "token" => ctx.device.token}, ctx.state)

    notice = %{
      "class" => "session.retired",
      "refs" => %{"sessionKey" => "agent:worker"},
      "payload" => %{"sessionKey" => "agent:worker", "ownerUserId" => "flynn"}
    }

    assert {:stop, :normal, 1008, ^state} =
             ChangeSocket.handle_info({:firehose_notice, notice}, state)
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

    held_admin_classes =
      ~w(config.updated host_env.updated identity.updated host.registered kungfu.updated user.promoted)

    assert held_admin_classes -- Registry.classes() == held_admin_classes
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
end
