defmodule Tightbeam.RestCoreDetailRoutesTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{
    Archetypes,
    Artifacts,
    Assignments,
    DB,
    Devices,
    Identity,
    Ledger,
    ReadMarkers,
    Schema,
    StateResources,
    Wakes,
    WorkItems
  }

  alias Tightbeam.Firehose.Publisher
  alias Tightbeam.Wire.Router

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-core-detail-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    :initialized = Identity.init!(base_dir)
    Archetypes.load!(base_dir)

    db = :"core_detail_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)

    {:paired, admin_device} =
      claim_org(db, %{
        device_id: "core-admin-device",
        claimed_name: "Flynn",
        platform: nil,
        model: nil
      })

    admin_session = ensure_main_session(db, "flynn")

    work_item =
      WorkItems.__handle__(db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: nil,
        params: %{title: "Core detail fixture"}
      })

    assignment =
      Assignments.__handle__(db, "assign", %{
        verb: "assign",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: admin_session.session_key,
        target_role: nil,
        role_fallback: false,
        supervision_interval_ms: 60_000,
        params: %{
          subject: "Core detail assignment",
          idempotency_key: nil,
          reviews_assignment_id: nil,
          work_item_id: work_item.id,
          files: ["lib/tightbeam/wire/router.ex"]
        }
      })

    wake =
      Wakes.schedule(db, %{
        session_key: admin_session.session_key,
        origin: "user:flynn",
        prompt: "Core detail wake",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: admin_session.session_key,
        work_item_id: work_item.id,
        assignment_id: assignment.id
      })

    {:ok, turn_seq} =
      Ledger.enqueue(db, %{
        session_key: admin_session.session_key,
        message_id: "core-detail-message",
        origin: "user:flynn",
        prompt: "Core detail turn",
        assignment_id: assignment.id,
        job_ref: work_item.id
      })

    decision_request_id = "dr_core_detail"
    now = System.system_time(:millisecond)

    {:ok, _rows} =
      DB.query(
        db,
        """
        INSERT INTO decision_requests
          (id, kind, raiserId, ownerUserId, raisedAt, deadlineAt, statuteName,
           actionKey, question, context, status)
        VALUES (?1, 'statute', 'user:flynn', 'flynn', ?2, ?3, 'core-detail',
                'read', 'Allow the read?', '{}', 'open')
        """,
        [decision_request_id, now, now + 60_000]
      )

    artifact =
      Artifacts.record(db, %{
        principal: {:session, admin_session.session_key},
        session_key: admin_session.session_key,
        params: %{
          kind: "report",
          title: "Core detail report",
          origin_path: "reports/core-detail.md",
          work_item_id: work_item.id
        }
      })

    {:ok, true, %{marker: "cursor"}} =
      ReadMarkers.set(db, "flynn", "core-scope", "cursor")

    catalog = %{
      {"testhost", "claude"} => [
        %{family: "fable", context: nil, efforts: ["medium"], provider: :anthropic}
      ]
    }

    opts = [
      db: db,
      base_dir: base_dir,
      handlers: %{},
      cli_token: "tbc_core_detail",
      cursor_signing: cursor_signing!(base_dir),
      model_catalog: catalog,
      session_status: fn _ -> nil end
    ]

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{
      db: db,
      opts: opts,
      token: admin_device.token,
      admin_device: admin_device,
      admin_session: admin_session,
      work_item: work_item,
      assignment: assignment,
      wake: wake,
      turn_seq: turn_seq,
      decision_request_id: decision_request_id,
      artifact: artifact,
      catalog: catalog
    }
  end

  test "the closed nine-route inventory returns exact shared item bytes", ctx do
    cases = core_detail_cases(ctx)

    for %{resource: resource, path: path, item: item} <- cases do
      item_bytes = StateResources.encode_item(resource, item, ctx.catalog)
      response = get(ctx, path)

      assert response.status == 200, "#{path}: #{response.resp_body}"
      assert get_resp_header(response, "content-type") == ["application/json; charset=utf-8"]
      assert get_resp_header(response, "cache-control") == ["no-store"]

      assert response.resp_body ==
               ~s({"schemaVersion":1,"resource":#{JSON.encode!(resource)},"item":#{item_bytes}})
    end
  end

  test "A6 uses identical shared encoder bytes for REST items and notice payloads", ctx do
    for %{resource: resource, path: path, item: item, row: row, class: class, refs: refs} <-
          core_detail_cases(ctx) do
      item_bytes = StateResources.encode_item(resource, item, ctx.catalog)
      response = get(ctx, path)
      notice = Publisher.committed_notice(class, row, refs)
      notice_bytes = Publisher.encode_wire_notice(notice, ctx.catalog)

      assert response.resp_body =~ ~s("item":#{item_bytes})
      assert notice_bytes =~ ~s("payload":#{item_bytes})
    end
  end

  test "unknown, forbidden, and noncanonical keys use the closed 404", ctx do
    Devices.add_user(ctx.db, "outsider", false)

    {:pending, _device} =
      Devices.pair(ctx.db, %{
        device_id: "outsider-device",
        claimed_name: "Outsider",
        platform: nil,
        model: nil
      })

    outsider = Devices.approve(ctx.db, "outsider-device", "outsider")
    forbidden = get(ctx, "/api/work-items/#{ctx.work_item.id}", outsider.token)
    unknown = get(ctx, "/api/work-items/wi_missing", outsider.token)

    assert forbidden.status == 404
    assert forbidden.resp_body == unknown.resp_body

    for spelling <- ~w(0 01 +1 -1 1.0 1e0 999999999999999999999999999999999) do
      response = get(ctx, "/api/turns/#{URI.encode(spelling)}")
      assert response.status == 404, spelling
      assert error_code(response) == "not_found"
    end
  end

  test "all nine routes preserve D1 auth and query precedence", ctx do
    for %{path: path} <- core_detail_cases(ctx) do
      unauthenticated = get(ctx, path, "")
      invalid = get(ctx, path, "invalid-token")
      malformed = get(ctx, path <> "?asUser=flynn%zz")
      unsupported = get(ctx, path <> "?unsupported=1")
      elevated_device = get(ctx, path <> "?asUser=flynn")

      assert {unauthenticated.status, error_code(unauthenticated)} == {401, "auth_failed"}, path
      assert {invalid.status, error_code(invalid)} == {401, "auth_failed"}, path
      assert {malformed.status, error_code(malformed)} == {400, "malformed_query"}, path
      assert {unsupported.status, error_code(unsupported)} == {400, "invalid_filter"}, path

      assert {elevated_device.status, error_code(elevated_device)} ==
               {400, "invalid_as_user"},
             path
    end

    marker_as_session = get(ctx, "/api/read-markers/core-scope", ctx.admin_session.cli_token)
    assert {marker_as_session.status, error_code(marker_as_session)} == {404, "not_found"}
  end

  test "turn and device expose one canonical key and authoritative refs", ctx do
    turn_row = StateResources.query_turn_by_seq(ctx.db, ctx.turn_seq)
    turn = StateResources.turn(turn_row)

    device =
      ctx.db |> StateResources.query_device(ctx.admin_device.device_id) |> StateResources.device()

    assert turn["seq"] == ctx.turn_seq
    refute Map.has_key?(turn, "turnSeq")
    assert device["deviceId"] == ctx.admin_device.device_id
    refute Map.has_key?(device, "id")

    turn_notice =
      Publisher.committed_notice("turn.started", turn_row, %{
        "sessionKey" => ctx.admin_session.session_key
      })

    device_notice = Publisher.committed_notice("device.approved", device, %{})

    assert turn_notice["refs"]["turnSeq"] == ctx.turn_seq
    assert device_notice["refs"]["deviceId"] == ctx.admin_device.device_id
  end

  test "the shared seams contain no composite CLI or prefix fallback" do
    resources = File.read!(Path.expand("../lib/tightbeam/state_resources.ex", __DIR__))
    router = File.read!(Path.expand("../lib/tightbeam/wire/router.ex", __DIR__))

    refute resources =~ "WorkItems.__handle__"
    refute resources =~ "Assignments.__handle__"
    refute resources =~ "IdPrefix"
    refute router =~ "StateVisibility.core_detail_visible?"
    assert resources =~ "defp detail_selection"

    matches =
      Regex.scan(
        ~r/get "\/api\/(?:work-items|assignments|wakes|turns|decision-requests|sessions|devices|artifacts|read-markers)\/:/,
        router
      )

    assert length(matches) == 9
  end

  defp core_detail_cases(ctx) do
    call = %{
      principal: {:user, "flynn"},
      rest_principal: %{kind: "user", id: "flynn", is_admin: true},
      params: %{}
    }

    [
      case_row(
        "work items",
        "/api/work-items/#{ctx.work_item.id}",
        "work_item.created",
        %{"workItemId" => ctx.work_item.id},
        StateResources.query_work_item(ctx.db, ctx.work_item.id, call),
        &StateResources.work_item/1
      ),
      case_row(
        "assignments",
        "/api/assignments/#{ctx.assignment.id}",
        "assignment.opened",
        %{"assignmentId" => ctx.assignment.id},
        StateResources.query_assignment(ctx.db, ctx.assignment.id, call),
        &StateResources.assignment/1
      ),
      case_row(
        "wakes",
        "/api/wakes/#{ctx.wake.wake_id}",
        "wake.scheduled",
        %{"wakeId" => ctx.wake.wake_id},
        StateResources.query_wake(ctx.db, ctx.wake.wake_id),
        &StateResources.wake/1
      ),
      case_row(
        "turns",
        "/api/turns/#{ctx.turn_seq}",
        "turn.started",
        %{"turnSeq" => ctx.turn_seq},
        StateResources.query_turn_by_seq(ctx.db, ctx.turn_seq),
        &StateResources.turn/1
      ),
      case_row(
        "decision requests",
        "/api/decision-requests/#{ctx.decision_request_id}",
        "decision_request.opened",
        %{"decisionRequestId" => ctx.decision_request_id},
        StateResources.query_decision_request(ctx.db, ctx.decision_request_id),
        &StateResources.decision_request/1
      ),
      case_row(
        "sessions",
        "/api/sessions/#{ctx.admin_session.session_key}",
        "session.spawned",
        %{"sessionKey" => ctx.admin_session.session_key},
        StateResources.query_session(ctx.db, ctx.admin_session.session_key),
        &StateResources.session/1
      ),
      case_row(
        "devices",
        "/api/devices/#{ctx.admin_device.device_id}",
        "device.approved",
        %{"deviceId" => ctx.admin_device.device_id},
        StateResources.query_device(ctx.db, ctx.admin_device.device_id),
        &StateResources.device/1
      ),
      case_row(
        "artifacts",
        "/api/artifacts/#{ctx.artifact.artifact_id}",
        "artifact.recorded",
        %{"artifactId" => ctx.artifact.artifact_id},
        StateResources.query_artifact(ctx.db, ctx.artifact.artifact_id),
        &StateResources.artifact/1
      ),
      case_row(
        "read markers",
        "/api/read-markers/core-scope",
        "read_marker.updated",
        %{"userId" => "flynn", "scopeKey" => "core-scope"},
        StateResources.query_read_marker(ctx.db, "flynn", "core-scope"),
        &StateResources.read_marker/1
      )
    ]
  end

  defp case_row(resource, path, class, refs, row, serializer) do
    %{resource: resource, path: path, class: class, refs: refs, row: row, item: serializer.(row)}
  end

  defp get(ctx, path, bearer \\ nil) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{bearer || ctx.token}")
    |> Router.call(Router.init(ctx.opts))
  end

  defp error_code(response), do: JSON.decode!(response.resp_body)["error"]["code"]
end
