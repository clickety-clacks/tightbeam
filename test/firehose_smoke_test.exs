defmodule Tightbeam.FirehoseSmokeTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.ClientE2E.WS
  alias Tightbeam.Firehose.Hub
  alias Tightbeam.FirehoseAcceptanceFixture, as: Fixture

  @moduledoc """
  Firehose acceptance map: A5 slow-consumer 4008/reconnect/rebuild is automated
  here. `Tightbeam.FirehoseRestartSmokeTest` keeps that Card 1 journey in the
  normal suite and adds automated A5 gateway-kill recovery and A7 external-client
  restart proof on Linux and macOS CI.
  """

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
