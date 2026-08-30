defmodule Tightbeam.FirehoseSmokeTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.ClientE2E.WS
  alias Tightbeam.Firehose.{Hub, Publisher, Registry}
  alias Tightbeam.FirehoseAcceptanceFixture, as: Fixture

  @moduledoc """
  Firehose acceptance map: A4 has automated real-client model proof for the 16
  current-main classes whose bytes are immutable or carry a durable monotonic
  version. The closed census excludes 24 classes whose bytes can change without
  that ordering token; the only delete class is among those exclusions. The four
  specified R8b observe frames prove client-side non-mutation and refetch over the
  real socket, but current main has no R8b registry or emission rows. A4 therefore
  remains partial for the excluded delete/recreate edge and production R8b emission.

  A5 slow-consumer 4008/reconnect/rebuild and gateway-kill recovery are automated
  here. `Tightbeam.FirehoseRestartSmokeTest` keeps that Card 1 journey in the
  normal suite and adds automated A5 gateway-kill recovery and A7 external-client
  restart proof on Linux and macOS CI.
  """

  @a4_versioned %{
    "config.updated" => :admin_projection_versions,
    "critical_lease.updated" => :critical_lease_updated_at,
    "device.approved" => :device_versions,
    "device.denied" => :device_versions,
    "device.revoked" => :device_versions,
    "host.registered" => :admin_projection_versions,
    "host_env.updated" => :admin_projection_versions,
    "identity.updated" => :admin_projection_publication_stamp,
    "kungfu.updated" => :admin_projection_publication_stamp,
    "read_marker.updated" => :read_marker_updated_at,
    "user.added" => :admin_projection_versions,
    "user.promoted" => :admin_projection_versions
  }

  @a4_immutable %{
    "attest.filed" => :append_only,
    "condition_fact.filed" => :append_only,
    "message.created" => :append_only,
    "prod.fired" => :append_only
  }

  @a4_incompatible %{
    "artifact.recorded" => :mutable_wall_clock_version,
    "assignment.closed" => :reopen_removes_closed_version,
    "assignment.opened" => :reopen_removes_closed_version,
    "assignment.reopened" => :reopen_removes_closed_version,
    "decision_request.opened" => :mutable_wall_clock_version,
    "decision_request.returned" => :mutable_wall_clock_version,
    "decision_request.ruled" => :mutable_wall_clock_version,
    "decision_request.withdrawn" => :mutable_wall_clock_version,
    "role.bound" => :mutable_wall_clock_version,
    "role.created" => :mutable_wall_clock_version,
    "role.removed" => :delete_without_version_floor,
    "session.retired" => :mutable_wall_clock_version,
    "session.spawned" => :mutable_wall_clock_version,
    "turn.ended" => :mutable_wall_clock_version,
    "turn.started" => :mutable_wall_clock_version,
    "wake.canceled" => :mutable_wall_clock_version,
    "wake.fired" => :mutable_wall_clock_version,
    "wake.scheduled" => :mutable_wall_clock_version,
    "work_item.closed" => :created_at_only,
    "work_item.created" => :created_at_only,
    "work_item.failed" => :created_at_only,
    "work_item.iceboxed" => :created_at_only,
    "work_item.reopened" => :created_at_only,
    "work_item.updated" => :created_at_only
  }

  @r8b_classes ~w(
    topline.created
    topline_work_membership.linked
    topline_work_membership.unlinked
    subagent_marker.appended
  )

  @model_seed {7_913, 10_007, 65_537}
  @model_sequences [
    [:older, :newer, :duplicate, :older],
    [:newer, :older, :duplicate, :older],
    [:older, :duplicate_old, :newer, :duplicate],
    [:newer, :duplicate, :older, :older],
    [:older, :newer, :older, :duplicate],
    [:newer, :older, :older, :duplicate]
  ]

  test "A4 compatibility census closes the registry and reproduces the work-item collision" do
    classified =
      Map.keys(@a4_versioned) ++ Map.keys(@a4_immutable) ++ Map.keys(@a4_incompatible)

    assert Enum.sort(classified) == Registry.rows() |> Map.keys() |> Enum.sort()
    assert length(classified) == length(Enum.uniq(classified))
    assert map_size(@a4_versioned) == 12
    assert map_size(@a4_immutable) == 4
    assert map_size(@a4_incompatible) == 24
    assert Enum.all?(@r8b_classes, &(Registry.fetch(&1) == :error))

    assert Registry.rows()
           |> Enum.filter(fn {_class, row} -> row.op == "delete" end)
           |> Enum.map(&elem(&1, 0)) == ["role.removed"]

    assert Enum.all?(Map.keys(@a4_versioned) ++ Map.keys(@a4_immutable), fn class ->
             {:ok, row} = Registry.fetch(class)
             row.op == "upsert"
           end)

    fixture = start_fixture!()
    id = Fixture.create_item(fixture, "A4 collision before")
    before = Fixture.snapshot(fixture)[id]
    Fixture.update_item(fixture, id, "A4 collision after")
    after_update = Fixture.snapshot(fixture)[id]

    assert before["rowVersion"] == after_update["rowVersion"]
    refute JSON.encode!(before) == JSON.encode!(after_update)
  end

  test "A4 deterministic real-client model converges for the compatible subset and R8b refetch" do
    fixture = start_fixture!()
    assert fixture.device.is_admin

    classes =
      Map.keys(@a4_versioned) ++ Map.keys(@a4_immutable) ++ @r8b_classes

    ws =
      Fixture.connect(fixture,
        subscription_id: "a4-model",
        filters: %{"classes" => classes}
      )

    model = %{rows: %{}, versions: %{}, views: %{}, refetches: %{}}
    # The rebuild oracle records the newest committed payload for each resource key.
    # It never consumes the incremental delivery order below.
    rebuild_rows = %{}
    random = :rand.seed_s(:exsplus, @model_seed)

    {model, rebuild_rows, ws, _random} =
      @a4_versioned
      |> Map.keys()
      |> Enum.sort()
      |> Enum.with_index()
      |> Enum.reduce(
        {model, rebuild_rows, ws, random},
        fn {class, class_index}, {model, rebuild_rows, ws, random} ->
          {sequences, random} = seeded_sequences(random)

          {model, rebuild_rows, ws} =
            sequences
            |> Enum.with_index()
            |> Enum.reduce(
              {model, rebuild_rows, ws},
              fn {sequence, sequence_index}, {model, rebuild_rows, ws} ->
                label = model_label(class, class_index, sequence_index)
                older = model_notice(class, label, sequence_index * 2 + 101, :older, fixture)
                newer = model_notice(class, label, sequence_index * 2 + 102, :newer, fixture)
                key = model_key(newer)

                assert model_key(older) == key
                assert older["payload"]["rowVersion"] < newer["payload"]["rowVersion"]

                rebuild_rows = Map.put(rebuild_rows, key, newer["payload"])

                {model, ws} =
                  Enum.reduce(sequence, {model, ws}, fn step, {model, ws} ->
                    notice = sequence_notice(step, older, newer)
                    :ok = Hub.publish(fixture.hub, notice)
                    {frame, ws} = Fixture.recv_change(ws)
                    assert frame["class"] == class
                    assert frame["payload"] == notice["payload"]
                    {apply_model_notice(model, frame, fn _ -> flunk("R8 refetched") end), ws}
                  end)

                assert model.rows == rebuild_rows,
                       "A4 seed=#{inspect(@model_seed)} class=#{class} sequence=#{inspect(sequence)}"

                {model, rebuild_rows, ws}
              end
            )

          {model, rebuild_rows, ws, random}
        end
      )

    {model, rebuild_rows, ws} =
      @a4_immutable
      |> Map.keys()
      |> Enum.sort()
      |> Enum.with_index()
      |> Enum.reduce({model, rebuild_rows, ws}, fn {class, index}, {model, rebuild_rows, ws} ->
        notice = model_notice(class, "immutable-#{index}", index + 10_001, :only, fixture)
        key = model_key(notice)
        rebuild_rows = Map.put(rebuild_rows, key, notice["payload"])

        {model, ws} =
          Enum.reduce(1..2, {model, ws}, fn _duplicate, {model, ws} ->
            :ok = Hub.publish(fixture.hub, notice)
            {frame, ws} = Fixture.recv_change(ws)
            assert frame["class"] == class
            assert frame["payload"] == notice["payload"]
            {apply_model_notice(model, frame, fn _ -> flunk("R8 refetched") end), ws}
          end)

        assert model.rows == rebuild_rows
        {model, rebuild_rows, ws}
      end)

    initial_rows = model.rows

    {model, ws} =
      @r8b_classes
      |> Enum.with_index(1)
      |> Enum.reduce({model, ws}, fn {class, source_version}, {model, ws} ->
        snapshot = %{"class" => class, "revision" => source_version, "rows" => [source_version]}
        notice = r8b_notice(class, source_version)

        {model, ws} =
          Enum.reduce(1..2, {model, ws}, fn expected_refetches, {model, ws} ->
            :ok = Hub.publish(fixture.hub, notice)
            {frame, ws} = Fixture.recv_change(ws)
            assert frame["class"] == class
            refute Map.has_key?(frame, "resource")
            assert frame["op"] == "observe"
            assert frame["refs"] == notice["refs"]
            assert frame["payload"] == %{"sourceVersion" => source_version}

            model =
              apply_model_notice(model, frame, fn ^class ->
                snapshot
              end)

            assert model.rows == initial_rows
            assert model.views[class] == snapshot
            assert model.refetches[class] == expected_refetches
            {model, ws}
          end)

        {model, ws}
      end)

    assert model.rows == rebuild_rows
    :ok = WS.close(ws)
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

  defp model_label(class, class_index, sequence_index) do
    class = String.replace(class, ".", "-")
    "#{class}-#{class_index}-#{sequence_index}"
  end

  defp sequence_notice(step, older, newer) do
    case step do
      :older -> older
      :duplicate_old -> older
      :newer -> newer
      :duplicate -> newer
    end
  end

  defp model_notice(class, label, row_version, generation, fixture) do
    row = Map.fetch!(Registry.rows(), class)
    payload = model_payload(row.resource, label, row_version, generation)

    Publisher.committed_notice(class, payload, %{"ownerUserId" => fixture.user_id})
  end

  defp model_payload("attests", label, row_version, generation) do
    %{
      id: "att_a4_#{label}",
      kind: "progress",
      note: "#{generation}",
      ts: row_version
    }
  end

  defp model_payload("condition-facts", _label, row_version, generation) do
    %{fact_id: row_version, kind: "a4-#{generation}", origin: "process:tightbeam", ts: 1}
  end

  defp model_payload("messages", label, row_version, generation) do
    %{
      id: "s_a4_#{label}",
      seq: row_version,
      session_key: "agent:a4:#{label}",
      role: "assistant",
      sender: "process:tightbeam",
      content: "#{generation}",
      message_type: "substrate"
    }
  end

  defp model_payload("productions", label, row_version, generation) do
    %{
      seq: row_version,
      at: 1,
      kind: "prod_fired",
      job_ref: "wi_a4_#{label}",
      detail: %{"generation" => "#{generation}"}
    }
  end

  defp model_payload("users", label, row_version, generation) do
    %{
      user_id: "a4-user-#{label}",
      is_admin: generation == :newer,
      created_at: 1,
      row_version: row_version
    }
  end

  defp model_payload("devices", label, row_version, generation) do
    %{
      device_id: "a4-device-#{label}",
      claimed_name: "A4 device",
      status: if(generation == :newer, do: "allowlisted", else: "pending"),
      created_at: 1,
      row_version: row_version
    }
  end

  defp model_payload("read-markers", label, row_version, generation) do
    %{
      user_id: "a4-user",
      scope_key: "a4-scope-#{label}",
      marker: "#{generation}",
      updated_at: row_version
    }
  end

  defp model_payload("critical-state", label, row_version, generation) do
    %{
      session_key: "agent:a4:#{label}",
      reason: "#{generation}",
      started_at: 1,
      expires_at: 2,
      hard_deadline: 3,
      updated_at: row_version
    }
  end

  defp model_payload("config", label, row_version, generation) do
    %{
      key: "a4-#{label}",
      value: "#{generation}",
      updated_at: row_version,
      row_version: row_version
    }
  end

  defp model_payload("host environment", label, row_version, generation) do
    %{
      host: "a4-host",
      harness: "fixture",
      name: "A4_#{label}",
      value_present: generation == :newer,
      updated_at: row_version,
      row_version: row_version
    }
  end

  defp model_payload("hosts", label, row_version, _generation) do
    %{host: "a4-host-#{label}", row_version: row_version}
  end

  defp model_payload("identity", label, row_version, generation) do
    %{
      name: "a4-identity-#{label}",
      live_revision: "#{generation}-#{label}",
      state: "ready",
      session_revisions: %{},
      staleness: [],
      conflicts: [],
      row_version: row_version
    }
  end

  defp model_payload("kungfu", label, row_version, generation) do
    %{
      name: "a4-kungfu-#{label}",
      purpose: "A4 #{generation}",
      phrases: ["a4"],
      root_archetype: "default",
      installed_revision: nil,
      status: "available",
      documents: [],
      row_version: row_version
    }
  end

  defp model_key(%{"class" => class, "refs" => refs}) do
    row = Map.fetch!(Registry.rows(), class)
    {row.resource, Enum.map(row.primary_refs, &Map.fetch!(refs, &1))}
  end

  defp seeded_sequences(random) do
    {keyed, random} =
      @model_sequences
      |> Enum.with_index()
      |> Enum.map_reduce(random, fn {sequence, index}, random ->
        {key, random} = :rand.uniform_s(1_000_000, random)
        {{key, index, sequence}, random}
      end)

    sequences = keyed |> Enum.sort() |> Enum.map(&elem(&1, 2))
    {sequences, random}
  end

  defp apply_model_notice(model, %{"op" => "observe", "class" => class}, refetch) do
    snapshot = refetch.(class)

    %{
      model
      | views: Map.put(model.views, class, snapshot),
        refetches: Map.update(model.refetches, class, 1, &(&1 + 1))
    }
  end

  defp apply_model_notice(model, %{"op" => "upsert", "payload" => payload} = notice, _refetch) do
    key = model_key(notice)
    version = Map.fetch!(payload, "rowVersion")
    current_version = Map.get(model.versions, key, 0)

    if version > current_version do
      %{
        model
        | rows: Map.put(model.rows, key, payload),
          versions: Map.put(model.versions, key, version)
      }
    else
      model
    end
  end

  defp r8b_notice(class, source_version) do
    %{
      "class" => class,
      "op" => "observe",
      "occurredAt" => source_version,
      "refs" => r8b_refs(class, source_version),
      "payload" => %{"sourceVersion" => source_version}
    }
  end

  defp r8b_refs("topline.created", version),
    do: %{"toplineId" => "tl_a4_#{version}"}

  defp r8b_refs("topline_work_membership.linked", version) do
    %{
      "toplineId" => "tl_a4_#{version}",
      "membershipId" => "tlm_a4_#{version}",
      "workItemId" => "wi_a4_#{version}"
    }
  end

  defp r8b_refs("topline_work_membership.unlinked", version) do
    %{
      "toplineId" => "tl_a4_#{version}",
      "membershipId" => "tlm_a4_#{version}",
      "workItemId" => "wi_a4_#{version}"
    }
  end

  defp r8b_refs("subagent_marker.appended", version) do
    %{
      "markerId" => Integer.to_string(version),
      "sessionKey" => "agent:a4:#{version}",
      "assignmentId" => "asg_a4_#{version}",
      "workItemId" => "wi_a4_#{version}"
    }
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
