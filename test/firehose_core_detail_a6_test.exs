defmodule Tightbeam.Firehose.CoreDetailA6Test do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Org, Placement, ReadMarkers, StateResources, Wakes}
  alias Tightbeam.Firehose.{Publisher, Registry}
  alias Tightbeam.FirehoseAcceptanceFixture, as: Fixture

  @core_cases [
    %{
      resource: "work-items",
      rest_resource: "work items",
      classes:
        ~w(work_item.created work_item.updated work_item.iceboxed work_item.reopened work_item.closed work_item.failed),
      primary_refs: ["workItemId"]
    },
    %{
      resource: "assignments",
      rest_resource: "assignments",
      classes: ~w(assignment.opened assignment.reopened assignment.closed),
      primary_refs: ["assignmentId"]
    },
    %{
      resource: "wakes",
      rest_resource: "wakes",
      classes: ~w(wake.scheduled wake.fired wake.canceled),
      primary_refs: ["wakeId"]
    },
    %{
      resource: "turns",
      rest_resource: "turns",
      classes: ~w(turn.started turn.ended),
      primary_refs: ["turnSeq"]
    },
    %{
      resource: "decision-requests",
      rest_resource: "decision requests",
      classes:
        ~w(decision_request.opened decision_request.ruled decision_request.returned decision_request.withdrawn),
      primary_refs: ["decisionRequestId"]
    },
    %{
      resource: "sessions",
      rest_resource: "sessions",
      classes: ~w(session.spawned session.updated session.retired),
      primary_refs: ["sessionKey"]
    },
    %{
      resource: "devices",
      rest_resource: "devices",
      classes: ~w(device.approved device.denied device.revoked),
      primary_refs: ["deviceId"]
    },
    %{
      resource: "artifacts",
      rest_resource: "artifacts",
      classes: ~w(artifact.recorded),
      primary_refs: ["artifactId"]
    },
    %{
      resource: "read-markers",
      rest_resource: "read markers",
      classes: ~w(read_marker.updated),
      primary_refs: ["userId", "scopeKey"]
    }
  ]

  @core_routes [
    "/api/work-items/:key",
    "/api/assignments/:key",
    "/api/wakes/:key",
    "/api/turns/:key",
    "/api/decision-requests/:key",
    "/api/sessions/:key",
    "/api/devices/:key",
    "/api/artifacts/:key",
    "/api/read-markers/:key"
  ]

  setup do
    catalog =
      Map.new(Tightbeam.Harness.all(), fn harness ->
        entries =
          if harness.wire_name() == "claude" do
            [%{family: "fable", context: nil, efforts: [], provider: :anthropic}]
          else
            []
          end

        {{Placement.local_host_name(), harness.wire_name()}, entries}
      end)

    fixture = Fixture.start!(model_catalog: catalog)
    on_exit(fn -> assert :ok = Fixture.stop(fixture) end)

    main_session_key = Org.personal_session_key(fixture.user_id)
    _main = ensure_main_session(fixture.db, fixture.user_id)

    :ok = seed_core_rows(fixture, main_session_key)

    %{fixture: fixture, catalog: catalog, main_session_key: main_session_key}
  end

  test "A6 closes the nine-route class and route inventories" do
    expected_rows =
      for spec <- @core_cases,
          class <- spec.classes,
          into: %{} do
        {class,
         %{
           resource: spec.resource,
           op: "upsert",
           primary_refs: spec.primary_refs
         }}
      end

    resources = MapSet.new(@core_cases, & &1.resource)

    actual_rows =
      Registry.rows()
      |> Enum.filter(fn {_class, row} -> MapSet.member?(resources, row.resource) end)
      |> Map.new(fn {class, row} ->
        {class, Map.take(row, [:resource, :op, :primary_refs])}
      end)

    assert actual_rows == expected_rows

    routes =
      ~r/get "(\/api\/(?:work-items|assignments|wakes|turns|decision-requests|sessions|devices|artifacts|read-markers)\/:[^"\/]+)" do/
      |> Regex.scan(File.read!("lib/tightbeam/wire/router.ex"), capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&Regex.replace(~r/:[^\/]+$/, &1, ":key"))

    assert Enum.sort(routes) == Enum.sort(@core_routes)
  end

  test "A6 compares every core R8 payload with its real REST detail item bytes", ctx do
    for spec <- @core_cases,
        class <- spec.classes do
      source_row = source_row!(ctx, spec.resource)
      refs = source_refs(spec.resource, source_row, ctx)
      notice = Publisher.committed_notice(class, source_row, refs)

      assert notice["class"] == class
      assert notice["resource"] == spec.resource
      assert notice["op"] == "upsert"
      assert notice["refs"] == refs

      notice_bytes = Publisher.encode_wire_notice(notice, ctx.catalog)
      payload_bytes = json_object_member_bytes!(notice_bytes, "payload")

      path = detail_path!(spec.resource, notice["refs"])
      {200, headers, detail_bytes} = http_get(ctx.fixture, path)
      item_bytes = detail_item_bytes!(detail_bytes, spec.rest_resource)

      assert application_header(headers, "content-type") ==
               "application/json; charset=utf-8"

      assert application_header(headers, "cache-control") == "no-store"
      assert payload_bytes == item_bytes, "#{class} payload bytes differ from #{path}"

      item = JSON.decode!(item_bytes)
      assert item == notice["payload"]
      assert is_integer(item["rowVersion"]) and item["rowVersion"] > 0
      assert StateResources.item_shape_complete?(spec.resource, item)
      refute StateResources.item_has_secret_fields?(item)
      refute detail_bytes =~ ctx.fixture.device.token
      refute detail_bytes =~ ctx.fixture.cli_token

      assert_primary_refs!(spec.resource, notice["refs"], item)
    end
  end

  defp seed_core_rows(fixture, main_session_key) do
    now = System.system_time(:millisecond)

    :ok =
      DB.execute(
        fixture.db,
        """
        INSERT INTO work_items
          (id,title,ownerUserId,state,createdByUser,
           createdContextKnown,createdAt)
        VALUES
          ('wi_a6_core','A6 core detail','#{fixture.user_id}','open',
           '#{fixture.user_id}',1,#{now});

        INSERT INTO assignments
          (id,subject,holderKey,openedByUser,openedAt,state,workItemId)
        VALUES
          ('asg_a6_core','Prove core detail','#{main_session_key}',
           '#{fixture.user_id}',#{now},'open','wi_a6_core');

        INSERT INTO turns
          (seq,sessionKey,messageId,origin,prompt,status,owner,createdAt,startedAt)
        VALUES
          (6001,'#{main_session_key}','msg_a6_core','user:#{fixture.user_id}',
           'A6 core turn','running','#{fixture.user_id}',#{now},#{now});

        INSERT INTO decision_requests
          (id,kind,raiserId,raiserSessionKey,ownerUserId,expecterSessionKey,
           expecterUserId,raisedAt,question,context,status)
        VALUES
          ('dr_a6_core','agent','session:#{main_session_key}','#{main_session_key}',
           '#{fixture.user_id}','#{main_session_key}','#{fixture.user_id}',#{now},
           'A6 core decision?','{}','open');

        INSERT INTO artifacts
          (artifactId,kind,title,createdBySession,workItemId,originPath,
           recordedTurnEvidence,state,createdAt,updatedAt)
        VALUES
          ('art_a6_core','report','A6 core artifact','#{main_session_key}',
           'wi_a6_core','reports/a6-core.md','none','in-workspace',#{now},#{now});
        """
      )

    _wake =
      Wakes.schedule(fixture.db, %{
        wake_id: "w_a6_core",
        session_key: main_session_key,
        origin: "user:#{fixture.user_id}",
        prompt: "A6 core wake",
        consumer: "prompt",
        due_at: now + 60_000,
        creator_session_key: main_session_key,
        work_item_id: "wi_a6_core",
        assignment_id: "asg_a6_core"
      })

    {:ok, true, _marker} =
      ReadMarkers.set(fixture.db, fixture.user_id, "scope-a6-core", "marker-a6-core")

    :ok
  end

  defp source_row!(ctx, "work-items") do
    StateResources.query_work_item(ctx.fixture.db, "wi_a6_core", detail_call(ctx))
  end

  defp source_row!(ctx, "assignments") do
    StateResources.query_assignment(ctx.fixture.db, "asg_a6_core", detail_call(ctx))
  end

  defp source_row!(ctx, "wakes"), do: StateResources.query_wake(ctx.fixture.db, "w_a6_core")

  defp source_row!(ctx, "turns") do
    apply(StateResources, :query_turn_by_seq, [ctx.fixture.db, 6001])
  end

  defp source_row!(ctx, "decision-requests") do
    apply(StateResources, :query_decision_request, [ctx.fixture.db, "dr_a6_core"])
  end

  defp source_row!(ctx, "sessions") do
    StateResources.query_session(ctx.fixture.db, ctx.main_session_key)
  end

  defp source_row!(ctx, "devices") do
    StateResources.query_device(ctx.fixture.db, ctx.fixture.device.device_id)
  end

  defp source_row!(ctx, "artifacts") do
    StateResources.query_artifact(ctx.fixture.db, "art_a6_core")
  end

  defp source_row!(ctx, "read-markers") do
    StateResources.query_read_marker(ctx.fixture.db, ctx.fixture.user_id, "scope-a6-core")
  end

  defp detail_call(ctx) do
    %{
      principal: {:user, ctx.fixture.user_id},
      rest_principal: %{
        kind: "user",
        id: ctx.fixture.user_id,
        is_admin: true
      },
      params: %{}
    }
  end

  defp source_refs("work-items", row, _ctx), do: %{"workItemId" => value(row, :id)}
  defp source_refs("assignments", row, _ctx), do: %{"assignmentId" => value(row, :id)}
  defp source_refs("wakes", row, _ctx), do: %{"wakeId" => value(row, :wake_id)}
  defp source_refs("turns", row, _ctx), do: %{"turnSeq" => value(row, :seq)}

  defp source_refs("decision-requests", row, _ctx),
    do: %{"decisionRequestId" => value(row, :id)}

  defp source_refs("sessions", row, _ctx), do: %{"sessionKey" => value(row, :session_key)}

  defp source_refs("devices", row, _ctx),
    do: %{"deviceId" => value(row, :device_id) || value(row, :id)}

  defp source_refs("artifacts", row, _ctx),
    do: %{"artifactId" => value(row, :artifact_id)}

  defp source_refs("read-markers", row, ctx) do
    %{
      "userId" => ctx.fixture.user_id,
      "scopeKey" => value(row, :scope_key)
    }
  end

  defp detail_path!("work-items", refs), do: "/api/work-items/#{refs["workItemId"]}"
  defp detail_path!("assignments", refs), do: "/api/assignments/#{refs["assignmentId"]}"
  defp detail_path!("wakes", refs), do: "/api/wakes/#{refs["wakeId"]}"
  defp detail_path!("turns", refs), do: "/api/turns/#{refs["turnSeq"]}"

  defp detail_path!("decision-requests", refs),
    do: "/api/decision-requests/#{refs["decisionRequestId"]}"

  defp detail_path!("sessions", refs), do: "/api/sessions/#{refs["sessionKey"]}"
  defp detail_path!("devices", refs), do: "/api/devices/#{refs["deviceId"]}"
  defp detail_path!("artifacts", refs), do: "/api/artifacts/#{refs["artifactId"]}"
  defp detail_path!("read-markers", refs), do: "/api/read-markers/#{refs["scopeKey"]}"

  defp assert_primary_refs!("work-items", refs, item),
    do: assert(refs["workItemId"] === item["id"])

  defp assert_primary_refs!("assignments", refs, item),
    do: assert(refs["assignmentId"] === item["id"])

  defp assert_primary_refs!("wakes", refs, item),
    do: assert(refs["wakeId"] === item["wakeId"])

  defp assert_primary_refs!("turns", refs, item) do
    assert refs["turnSeq"] === item["seq"]
    refute Map.has_key?(item, "turnSeq")
  end

  defp assert_primary_refs!("decision-requests", refs, item),
    do: assert(refs["decisionRequestId"] === item["id"])

  defp assert_primary_refs!("sessions", refs, item),
    do: assert(refs["sessionKey"] === item["sessionKey"])

  defp assert_primary_refs!("devices", refs, item) do
    assert refs["deviceId"] === item["deviceId"]
    refute Map.has_key?(item, "id")
  end

  defp assert_primary_refs!("artifacts", refs, item),
    do: assert(refs["artifactId"] === item["artifactId"])

  defp assert_primary_refs!("read-markers", refs, item) do
    assert {refs["userId"], refs["scopeKey"]} === {item["userId"], item["scopeKey"]}
  end

  defp http_get(fixture, path) do
    url = ~c"http://127.0.0.1:#{fixture.port}#{path}"

    {:ok, {{_version, status, _reason}, headers, body}} =
      :httpc.request(
        :get,
        {url, [{~c"authorization", ~c"Bearer #{fixture.device.token}"}]},
        [{:timeout, 2_000}],
        body_format: :binary
      )

    {status, headers, body}
  end

  defp application_header(headers, name) do
    name = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if key |> to_string() |> String.downcase() == name, do: to_string(value)
    end)
  end

  defp detail_item_bytes!(bytes, resource) do
    prefix = ~s({"schemaVersion":1,"resource":#{JSON.encode!(resource)},"item":)
    assert String.starts_with?(bytes, prefix)
    assert String.ends_with?(bytes, "}")
    binary_part(bytes, byte_size(prefix), byte_size(bytes) - byte_size(prefix) - 1)
  end

  defp json_object_member_bytes!(bytes, key) do
    marker = JSON.encode!(key) <> ":"
    {offset, marker_size} = :binary.match(bytes, marker)
    start = offset + marker_size
    extract_json_object!(bytes, start, start, 0, false, false)
  end

  defp extract_json_object!(bytes, start, index, depth, in_string?, escaped?) do
    <<_::binary-size(index), byte, _::binary>> = bytes

    {depth, in_string?, escaped?} =
      cond do
        in_string? and escaped? -> {depth, true, false}
        in_string? and byte == ?\\ -> {depth, true, true}
        in_string? and byte == ?\" -> {depth, false, false}
        in_string? -> {depth, true, false}
        byte == ?\" -> {depth, true, false}
        byte == ?{ -> {depth + 1, false, false}
        byte == ?} -> {depth - 1, false, false}
        true -> {depth, false, false}
      end

    if depth == 0 and index >= start do
      binary_part(bytes, start, index - start + 1)
    else
      extract_json_object!(bytes, start, index + 1, depth, in_string?, escaped?)
    end
  end

  defp value(row, key) do
    Map.get(row, key) || Map.get(row, Atom.to_string(key)) || Map.get(row, lower_camel(key))
  end

  defp lower_camel(key) do
    key
    |> Atom.to_string()
    |> String.split("_")
    |> then(fn [head | tail] -> head <> Enum.map_join(tail, &String.capitalize/1) end)
  end
end
