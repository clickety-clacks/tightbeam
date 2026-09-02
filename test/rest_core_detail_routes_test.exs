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
    Escalation,
    Identity,
    Ledger,
    Model,
    Org,
    ReadMarkers,
    Schema,
    StateResources,
    StateVisibility,
    Wakes,
    WorkItems
  }

  alias Tightbeam.ClientE2E.WS
  alias Tightbeam.Firehose.{Hub, Publisher, Registry}
  alias Tightbeam.Wire.Router

  @r7_fields %{
    "work items" =>
      ~w(id title specRefName specRefSha256 isBug ownerUserId state failReason routingWakeId slateWakeId createdByUser createdBySession createdInTurnSeq createdContextKnown createdAt rowVersion),
    "assignments" =>
      ~w(id subject holderKey holderRole holderFallback openedByUser openedBySession openedAt state outcome closedAt closedByUser closedBySession closingAttestId workItemId reviewsAssignmentId holderHarness holderProvider files effectKind derivedStatus rowVersion),
    "wakes" =>
      ~w(wakeId sessionKey targetRole origin prompt consumer dueAt state createdAt firedAt reresolve reresolveSeed reresolveRung conditionKind conditionScope conditionAfterId firedBy creatorSessionKey rumination workItemId assignmentId canceledAt targetGate class classElection deliveryRule digest summon rowVersion),
    "turns" =>
      ~w(seq sessionKey messageId wakeId origin prompt roleRef roleFallback assignmentId jobRef model thinkingLevel modelContext harness replyAttention status owner adapterGen requestRef error createdAt startedAt endedAt publishedAt rowVersion),
    "decision requests" =>
      ~w(id kind raiserId raiserSessionKey ownerUserId assignmentId expecterSessionKey expecterUserId lineageRung effortGeneration deadlineWakeId raisedAt deadlineAt statuteName question options context status decision rationale ruledBy ruledAt consumedAt withdrawnBy withdrawnReason withdrawnAt askedOfRole answer answeredBy answeredAt rowVersion),
    "sessions" =>
      ~w(sessionKey displayName kind orderIndex isBuiltIn adopted ownerUserId origin spawnedBy handle archetype overrides identityName identityRevision harness provider model thinkingLevel modelContext host clearedThroughSeq state createdAt updatedAt mechanicalStatus rowVersion),
    "devices" => ~w(deviceId userId claimedName status platform model createdAt rowVersion),
    "artifacts" =>
      ~w(artifactId kind title description createdBySession workItemId parentSession originPath contentSha256 recordedMessageId recordedTurnEvidence state home createdAt updatedAt rowVersion),
    "read markers" => ~w(userId scopeKey marker updatedAt rowVersion)
  }

  @nullable_fields %{
    "work items" =>
      ~w(specRefName specRefSha256 ownerUserId failReason routingWakeId slateWakeId createdByUser createdBySession createdInTurnSeq),
    "assignments" =>
      ~w(holderRole openedByUser openedBySession outcome closedAt closedByUser closedBySession closingAttestId workItemId reviewsAssignmentId holderHarness holderProvider),
    "wakes" =>
      ~w(targetRole prompt firedAt reresolve reresolveSeed reresolveRung conditionKind conditionScope conditionAfterId firedBy creatorSessionKey workItemId assignmentId canceledAt class classElection deliveryRule),
    "turns" =>
      ~w(messageId wakeId roleRef roleFallback assignmentId jobRef model thinkingLevel modelContext harness owner adapterGen requestRef error startedAt endedAt publishedAt),
    "decision requests" =>
      ~w(raiserId raiserSessionKey ownerUserId assignmentId expecterSessionKey expecterUserId deadlineWakeId deadlineAt statuteName decision rationale ruledBy ruledAt consumedAt withdrawnBy withdrawnReason withdrawnAt askedOfRole answer answeredBy answeredAt context),
    "sessions" =>
      ~w(ownerUserId spawnedBy handle identityName identityRevision provider model thinkingLevel modelContext host clearedThroughSeq overrides),
    "devices" => ~w(claimedName platform model),
    "artifacts" => ~w(description parentSession contentSha256 recordedMessageId home),
    "read markers" => []
  }

  @integer_fields %{
    "work items" => ~w(createdInTurnSeq createdAt rowVersion),
    "assignments" => ~w(openedAt closedAt rowVersion),
    "wakes" =>
      ~w(dueAt createdAt firedAt reresolveRung conditionAfterId canceledAt targetGate rowVersion),
    "turns" =>
      ~w(seq replyAttention adapterGen createdAt startedAt endedAt publishedAt rowVersion),
    "decision requests" =>
      ~w(lineageRung effortGeneration raisedAt deadlineAt ruledAt consumedAt withdrawnAt answeredAt rowVersion),
    "sessions" => ~w(orderIndex clearedThroughSeq createdAt updatedAt rowVersion),
    "devices" => ~w(createdAt rowVersion),
    "artifacts" => ~w(createdAt updatedAt rowVersion),
    "read markers" => ~w(updatedAt rowVersion)
  }

  @boolean_fields %{
    "work items" => ~w(isBug createdContextKnown),
    "assignments" => ~w(holderFallback),
    "wakes" => ~w(rumination digest summon),
    "turns" => [],
    "decision requests" => [],
    "sessions" => ~w(isBuiltIn adopted),
    "devices" => [],
    "artifacts" => [],
    "read markers" => []
  }

  @enum_domains %{
    {"work items", "state"} => ~w(open iceboxed closed failed),
    {"assignments", "state"} => ~w(open closed),
    {"assignments", "outcome"} => ~w(completed surrendered revoked),
    {"wakes", "state"} => ~w(pending fired canceled),
    {"wakes", "reresolve"} => ~w(lineage),
    {"wakes", "firedBy"} => ~w(condition fallback),
    {"wakes", "classElection"} => ~w(sender classifier batcher),
    {"turns", "status"} => ~w(queued running delivered canceled failed failed_unknown),
    {"decision requests", "kind"} => ~w(statute effort agent),
    {"decision requests", "status"} => ~w(open ruled consumed withdrawn superseded answered),
    {"sessions", "kind"} => ~w(main dm custom),
    {"sessions", "state"} => ~w(active retired),
    {"sessions", "mechanicalStatus"} => ~w(idle running),
    {"devices", "status"} => ~w(allowlisted pending denied),
    {"artifacts", "kind"} => ~w(spec report doc data other),
    {"artifacts", "recordedTurnEvidence"} => ~w(tool-call-observed session-concurrent none),
    {"artifacts", "state"} => ~w(in-workspace archived released)
  }

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-core-detail-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    :initialized = Identity.init!(base_dir)
    Archetypes.load!(base_dir)

    db = :"core_detail_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({Hub, name: Hub})
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
    effort_decision_request_id = "dr_core_detail_effort"
    agent_decision_request_id = "dr_core_detail_agent"
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

    {:ok, _rows} =
      DB.query(
        db,
        """
        INSERT INTO decision_requests
          (id, kind, raiserId, ownerUserId, assignmentId, expecterSessionKey,
           lineageRung, effortGeneration, deadlineWakeId, raisedAt, deadlineAt,
           question, context, status)
        VALUES (?1, 'effort', 'process:tightbeam', 'flynn', ?2, ?3,
                2, 1, ?4, ?5, ?6, 'Continue the effort?', '{}', 'open')
        """,
        [
          effort_decision_request_id,
          assignment.id,
          admin_session.session_key,
          wake.wake_id,
          now + 1,
          now + 60_001
        ]
      )

    {:ok, _rows} =
      DB.query(
        db,
        """
        INSERT INTO decision_requests
          (id, kind, raiserId, raiserSessionKey, ownerUserId,
           expecterSessionKey, expecterUserId, raisedAt, question, context,
           status, askedOfRole)
        VALUES (?1, 'agent', ?2, ?3, 'flynn', ?3, 'flynn', ?4,
                'Answer the agent?', '{}', 'open', 'coder:core-detail')
        """,
        [
          agent_decision_request_id,
          "session:#{admin_session.session_key}",
          admin_session.session_key,
          now + 2
        ]
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
      firehose_hub: Hub,
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
      decision_request_ids: %{
        statute: decision_request_id,
        effort: effort_decision_request_id,
        agent: agent_decision_request_id
      },
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
      assert_application_headers(response)

      assert response.resp_body ==
               ~s({"schemaVersion":1,"resource":#{JSON.encode!(resource)},"item":#{item_bytes}})
    end
  end

  test "AC11 captures real committed raw frames and compares payload bytes to HTTP item bytes",
       ctx do
    {:ok, queued_turn} =
      Ledger.claim_next(ctx.db, ctx.admin_session.session_key, "raw-a6-fixture-drain")

    :ok =
      Ledger.finish(ctx.db, queued_turn.seq, "delivered", nil,
        owner_lease: queued_turn.owner_lease
      )

    {port, ws} = start_change_server(ctx)
    {frames, ws} = committed_core_frames(ctx, port, ws)

    for %{
          class: class,
          resource: resource,
          path: path,
          raw: raw,
          http_status: http_status,
          http_headers: headers,
          http_body: body,
          source_refs: source_refs
        } <-
          frames do
      notice = JSON.decode!(raw)
      {:ok, registry} = Registry.fetch(class)

      assert http_status == 200, path
      assert notice["class"] == class
      assert notice["op"] == "upsert"
      assert notice["resource"] == registry.resource

      assert Map.take(notice["refs"], registry.primary_refs) ==
               Map.take(source_refs, registry.primary_refs)

      assert_source_ref_values(resource, notice["payload"], source_refs)
      assert is_integer(notice["payload"]["rowVersion"])
      assert application_header(headers, "content-type") == "application/json; charset=utf-8"
      assert application_header(headers, "cache-control") == "no-store"
      payload_bytes = raw_json_value(raw, "payload")
      item_bytes = raw_json_value(body, "item")

      assert payload_bytes == item_bytes,
             "#{class}\npayload=#{payload_bytes}\nitem=#{item_bytes}"

      assert item_bytes == StateResources.encode_item(resource, notice["payload"], ctx.catalog)
    end

    turn = Enum.find(frames, &(&1.resource == "turns")) |> then(&JSON.decode!(&1.raw))
    device = Enum.find(frames, &(&1.resource == "devices")) |> then(&JSON.decode!(&1.raw))

    assert turn["payload"]["seq"] == turn["refs"]["turnSeq"]
    refute Map.has_key?(turn["payload"], "turnSeq")
    assert device["payload"]["deviceId"] == device["refs"]["deviceId"]
    refute Map.has_key?(device["payload"], "id")
    :ok = WS.close(ws)
  end

  test "AC4 rejects every alternate string and numeric key spelling with the closed 404", ctx do
    for %{resource: resource} = row <- core_detail_cases(ctx),
        resource != "turns",
        variant <- string_key_variants(row) do
      response = get(ctx, variant)
      assert_error(response, 404, resource, "not_found")
      assert_application_headers(response)
    end

    for spelling <- [
          "0",
          "01",
          "+1",
          "-1",
          "1.0",
          "1e0",
          " 1",
          "1 ",
          "١",
          "9223372036854775808",
          "not-digits"
        ] do
      response = get(ctx, "/api/turns/#{URI.encode(spelling)}")
      assert_error(response, 404, "turns", "not_found")
      assert_application_headers(response)
    end
  end

  test "AC6 applies the complete AU2 precedence table with exact bytes and headers", ctx do
    for %{path: path, resource: resource} <- core_detail_cases(ctx) do
      cases = [
        {path, "", 401, "auth_failed", nil, [:bearer_auth]},
        {path, "invalid-token", 401, "auth_failed", nil, [:bearer_auth]},
        {path, "tbc_core_detail", 400, "invalid_message", nil,
         [:bearer_auth, :query_decode, :principal_resolution]},
        {path <> "?asUser=", "tbc_core_detail", 400, "invalid_message", nil,
         [:bearer_auth, :query_decode, :principal_resolution]},
        {path <> "?asUser=flynn&asUser=flynn", "tbc_core_detail", 400, "invalid_as_user", nil,
         [:bearer_auth, :query_decode, :principal_resolution]},
        {path <> "?asUser=mallory", ctx.admin_session.cli_token, 403, "identity_not_yours",
         "this session belongs to flynn", [:bearer_auth, :query_decode, :principal_resolution]},
        {path <> "?asUser=flynn", nil, 400, "invalid_as_user", nil,
         [:bearer_auth, :query_decode, :principal_resolution]},
        {path <> "?asUser=flynn%zz", nil, 400, "malformed_query", nil,
         [:bearer_auth, :query_decode]},
        {path <> "?unsupported=1", nil, 400, "invalid_filter", nil,
         [:bearer_auth, :query_decode, :principal_resolution, :request_validation]}
      ]

      for {request_path, bearer, status, code, message, operations} <- cases do
        {response, trace} = traced_get(ctx, request_path, bearer)
        assert_error(response, status, resource, code, message)
        assert_application_headers(response)
        assert operation_trace(trace, resource) == operations
        refute Enum.any?(trace, &match?({:sql_query, _, _}, &1))
        refute Enum.any?(trace, &match?({:shared_lookup, _, _}, &1))
      end
    end

    marker_as_session = get(ctx, "/api/read-markers/core-scope", ctx.admin_session.cli_token)
    assert_error(marker_as_session, 404, "read markers", "not_found")
    assert_application_headers(marker_as_session)
  end

  test "AC3 and AC7 trace one shared lookup, one fixed statement, one AU4 boundary, and one encoder",
       ctx do
    outsider = outsider_device(ctx)

    for row <- core_detail_cases(ctx) do
      {success, success_trace} = traced_get(ctx, row.path, ctx.token)
      assert success.status == 200
      assert_application_headers(success)
      assert_trace(success_trace, row, :success)

      {forbidden, forbidden_trace} = traced_get(ctx, row.path, outsider.token)
      {unknown, unknown_trace} = traced_get(ctx, unknown_path(row), outsider.token)

      assert_error(forbidden, 404, row.resource, "not_found")
      assert_application_headers(forbidden)
      assert_application_headers(unknown)
      assert forbidden.status == unknown.status
      assert forbidden.resp_body == unknown.resp_body
      assert response_application_headers(forbidden) == response_application_headers(unknown)
      assert fixed_selection_trace(forbidden_trace) == fixed_selection_trace(unknown_trace)
      assert_trace(forbidden_trace, row, :denied)
      assert_trace(unknown_trace, row, :denied)
    end
  end

  test "AC7 covers every nine-resource AU4 grant and all decision-request kinds", ctx do
    admin = %{kind: "user", id: "admin", is_admin: true}
    owner = %{kind: "user", id: "flynn", is_admin: false}
    session = %{kind: "session", id: ctx.admin_session.session_key, is_admin: false}
    denied_user = %{kind: "user", id: "outsider", is_admin: false}
    denied_session = %{kind: "session", id: "outsider-session", is_admin: false}

    grants = %{
      "work items" => [admin, owner, session],
      "assignments" => [admin, owner, session],
      "wakes" => [admin, owner, session],
      "turns" => [admin, owner, session],
      "decision requests" => [admin, owner],
      "sessions" => [admin, owner, session],
      "devices" => [admin],
      "artifacts" => [admin, owner, session],
      "read markers" => [owner]
    }

    for row <- core_detail_cases(ctx) do
      for principal <- Map.fetch!(grants, row.resource) do
        assert query_case(ctx, row, principal) != nil,
               "#{row.resource} denied #{inspect(principal)}"
      end

      for principal <- [denied_user, denied_session] -- Map.fetch!(grants, row.resource) do
        assert query_case(ctx, row, principal) == nil,
               "#{row.resource} admitted #{inspect(principal)}"
      end
    end

    for {kind, row, allowed, denied} <- decision_kind_rows(ctx) do
      for principal <- allowed do
        assert StateVisibility.core_detail_visible?(ctx.db, "decision requests", row, principal),
               "#{kind} denied #{inspect(principal)}"
      end

      refute StateVisibility.core_detail_visible?(ctx.db, "decision requests", row, denied),
             "#{kind} admitted #{inspect(denied)}"
    end

    outsider = outsider_device(ctx)

    for row <- decision_route_cases(ctx) do
      success = get(ctx, row.path)
      assert success.status == 200
      assert_application_headers(success)

      assert raw_json_value(success.resp_body, "item") ==
               StateResources.encode_item(row.resource, row.item, ctx.catalog)

      session = get(ctx, row.path, ctx.admin_session.cli_token)

      if row.kind == :statute do
        assert_error(session, 404, row.resource, "not_found")
      else
        assert session.status == 200
      end

      assert_application_headers(session)

      {forbidden, forbidden_trace} = traced_get(ctx, row.path, outsider.token)
      {unknown, unknown_trace} = traced_get(ctx, unknown_path(row), outsider.token)
      assert_error(forbidden, 404, row.resource, "not_found")
      assert forbidden.resp_body == unknown.resp_body
      assert_application_headers(forbidden)
      assert_application_headers(unknown)
      assert fixed_selection_trace(forbidden_trace) == fixed_selection_trace(unknown_trace)
    end
  end

  test "AC5 binds the same read-marker scope key to the resolved user", ctx do
    Devices.add_user(ctx.db, "alice", false)

    {:pending, _device} =
      Devices.pair(ctx.db, %{
        device_id: "alice-device",
        claimed_name: "Alice",
        platform: nil,
        model: nil
      })

    alice = Devices.approve(ctx.db, "alice-device", "alice")
    {:ok, true, _row} = ReadMarkers.set(ctx.db, "alice", "core-scope", "alice-cursor")

    flynn_response = get(ctx, "/api/read-markers/core-scope")
    alice_response = get(ctx, "/api/read-markers/core-scope", alice.token)

    assert JSON.decode!(flynn_response.resp_body)["item"] == %{
             "marker" => "cursor",
             "rowVersion" => JSON.decode!(flynn_response.resp_body)["item"]["rowVersion"],
             "scopeKey" => "core-scope",
             "updatedAt" => JSON.decode!(flynn_response.resp_body)["item"]["updatedAt"],
             "userId" => "flynn"
           }

    assert JSON.decode!(alice_response.resp_body)["item"]["userId"] == "alice"
    assert JSON.decode!(alice_response.resp_body)["item"]["marker"] == "alice-cursor"
    refute flynn_response.resp_body == alice_response.resp_body
    assert_application_headers(flynn_response)
    assert_application_headers(alice_response)
  end

  test "AC8 forces every shared failure stage to the closed projection error", ctx do
    for %{path: path, resource: resource} <- core_detail_cases(ctx),
        stage <- [:lookup, :schema, :serializer, :encoder] do
      probe = fn candidate_resource, candidate_stage ->
        if {candidate_resource, candidate_stage} == {resource, stage},
          do: raise(ArgumentError, "forced core-detail #{stage} failure")

        :ok
      end

      faulted = %{ctx | opts: Keyword.put(ctx.opts, :core_detail_probe, probe)}
      response = get(faulted, path)
      assert_error(response, 500, resource, "projection_invalid")
      assert_application_headers(response)
      refute response.resp_body =~ ~s("item":)
    end
  end

  test "AC9 ignores conditional validators and emits only the closed application headers", ctx do
    for %{path: path} <- core_detail_cases(ctx) do
      ordinary = get(ctx, path)

      conditional =
        get(ctx, path, nil, [
          {"if-none-match", ~s("stale")},
          {"if-modified-since", "Thu, 01 Jan 1970 00:00:00 GMT"}
        ])

      assert conditional.status == 200
      assert conditional.resp_body == ordinary.resp_body
      assert_application_headers(conditional)
    end
  end

  test "AC10 fixes all R7 shapes, types, secret structure, and 1,000-order bytes", ctx do
    populate_ac10_rows!(ctx)
    :rand.seed(:exsss, {29, 211, 997})

    for %{
          resource: resource,
          path: path,
          row: source_row,
          item: item,
          serializer: serializer
        } <-
          core_detail_cases(ctx) do
      expected_keys = Map.fetch!(@r7_fields, resource) |> MapSet.new()
      assert MapSet.new(Map.keys(item)) == expected_keys
      refute StateResources.item_has_secret_fields?(item)
      assert_wire_contract(resource, item)
      assert_populated_contract(resource, item)

      expected = StateResources.encode_item(resource, item, ctx.catalog)
      assert_ordered_fields(expected, Map.fetch!(@r7_fields, resource))
      response = get(ctx, path)
      assert response.status == 200
      assert_application_headers(response)
      assert raw_json_value(response.resp_body, "item") == expected

      for _iteration <- 1..1_000 do
        randomized_source = randomized_source(resource, source_row)
        randomized_item = serializer.(randomized_source)
        assert StateResources.encode_item(resource, randomized_item, ctx.catalog) == expected
      end
    end

    kinds =
      for row <- decision_route_cases(ctx) do
        response = get(ctx, row.path)
        assert response.status == 200
        assert_application_headers(response)

        assert raw_json_value(response.resp_body, "item") ==
                 StateResources.encode_item(row.resource, row.item, ctx.catalog)

        assert_wire_contract(row.resource, row.item)
        row.item["kind"]
      end

    assert kinds == ~w(statute effort agent)
  end

  @tag :timing
  @tag timeout: 600_000
  test "AC7 AU8 keeps 10,000 randomized forbidden and unknown requests per resource within 5%",
       ctx do
    outsider = outsider_device(ctx)

    results =
      timing_cases(ctx)
      |> Task.async_stream(
        fn row -> measure_same_404_pair(ctx, row, outsider.token) end,
        max_concurrency: min(System.schedulers_online(), 11),
        ordered: false,
        timeout: 600_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert length(results) == 11
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
    %{
      resource: resource,
      path: path,
      class: class,
      refs: refs,
      row: row,
      serializer: serializer,
      item: serializer.(row)
    }
  end

  defp populate_ac10_rows!(ctx) do
    opaque = "quote:\" snow:雪 newline:\n slash:\\end"
    now = System.system_time(:millisecond) + 10_000

    query!(
      ctx.db,
      """
      UPDATE work_items
      SET title = ?2, specRefName = 'rest-core-detail-routes-v1.md',
          specRefSha256 = ?3, isBug = 1, failReason = ?2,
          routingWakeId = ?4, slateWakeId = ?4, createdInTurnSeq = ?5,
          createdContextKnown = 1
      WHERE id = ?1
      """,
      [ctx.work_item.id, opaque, String.duplicate("a", 64), ctx.wake.wake_id, ctx.turn_seq]
    )

    query!(
      ctx.db,
      """
      UPDATE assignments
      SET subject = ?2, holderRole = 'coder:core-detail', holderFallback = 1,
          reviewsAssignmentId = id, holderHarness = 'claude', holderProvider = 'anthropic'
      WHERE id = ?1
      """,
      [ctx.assignment.id, opaque]
    )

    for path <- ["z-last.ex", "a-first.ex"] do
      query!(ctx.db, "INSERT INTO assignment_files (assignmentId, path) VALUES (?1, ?2)", [
        ctx.assignment.id,
        path
      ])
    end

    query!(
      ctx.db,
      """
      UPDATE wakes
      SET targetRole = 'coder:core-detail', prompt = ?2, state = 'fired', firedAt = ?3,
          reresolve = 'lineage', reresolveSeed = 'seed-雪', reresolveRung = 2,
          conditionKind = 'tests-passed', conditionScope = ?4, conditionAfterId = 7,
          firedBy = 'fallback', rumination = 1, canceledAt = ?3, targetGate = 0,
          class = 'input-needed', classElection = 'sender', deliveryRule = 'route-proof-v1',
          digest = 1, summon = 1
      WHERE wakeId = ?1
      """,
      [ctx.wake.wake_id, opaque, now, ctx.work_item.id]
    )

    query!(
      ctx.db,
      """
      UPDATE turns
      SET wakeId = ?2, prompt = ?3, roleRef = 'coder:core-detail', roleFallback = 1,
          model = 'fable', thinkingLevel = 'medium', harness = 'claude',
          replyAttention = 1, status = 'delivered', owner = 'owner-雪', adapterGen = 2,
          requestRef = 'request-ref', error = ?3, startedAt = ?4, endedAt = ?4,
          publishedAt = ?4
      WHERE seq = ?1
      """,
      [ctx.turn_seq, ctx.wake.wake_id, opaque, now]
    )

    query!(
      ctx.db,
      """
      UPDATE decision_requests
      SET question = ?2, options = ?3, context = ?4, status = 'ruled',
          decision = 'allow', rationale = ?2, ruledBy = 'user:flynn', ruledAt = ?5
      WHERE id = ?1
      """,
      [
        ctx.decision_request_id,
        opaque,
        JSON.encode!(["deny \"雪\"", "allow\nlater"]),
        JSON.encode!(%{"z" => %{"snow" => "雪"}, "a" => [1, true, nil, opaque]}),
        now
      ]
    )

    query!(
      ctx.db,
      """
      UPDATE sessions
      SET displayName = ?2, spawnedBy = sessionKey, handle = 'core-detail-handle', adopted = 1,
          overrides = ?3, identityName = 'core-detail-identity',
          identityRevision = 'rev-雪', thinkingLevel = 'medium',
          clearedThroughSeq = ?4, updatedAt = ?5
      WHERE sessionKey = ?1
      """,
      [
        ctx.admin_session.session_key,
        opaque,
        JSON.encode!(%{
          "skills_add" => ["zeta", "alpha", "snow-雪"],
          "guidance_extra" => opaque
        }),
        ctx.turn_seq,
        now
      ]
    )

    query!(
      ctx.db,
      "UPDATE devices SET claimedName = ?2, platform = 'linux-雪', model = 'model-x' WHERE deviceId = ?1",
      [ctx.admin_device.device_id, opaque]
    )

    query!(
      ctx.db,
      """
      UPDATE artifacts
      SET description = ?2, contentSha256 = ?3, recordedTurnEvidence = 'session-concurrent',
          state = 'archived', home = '/archive/雪', updatedAt = ?4
      WHERE artifactId = ?1
      """,
      [ctx.artifact.artifact_id, opaque, String.duplicate("b", 64), now]
    )

    assert {:ok, true, _marker} =
             ReadMarkers.set(ctx.db, "flynn", "core-scope", opaque)
  end

  defp query!(db, sql, params) do
    assert {:ok, _rows} = DB.query(db, sql, params)
  end

  defp assert_wire_contract(resource, item) do
    for field <- Map.fetch!(@r7_fields, resource) do
      value = Map.fetch!(item, field)

      cond do
        is_nil(value) ->
          assert field in Map.fetch!(@nullable_fields, resource),
                 "#{resource}.#{field} is unexpectedly nullable"

        field == "rowVersion" ->
          assert is_integer(value) and value > 0

        domain = Map.get(@enum_domains, {resource, field}) ->
          assert value in domain,
                 "#{resource}.#{field}=#{inspect(value)} is outside #{inspect(domain)}"

        field in Map.fetch!(@integer_fields, resource) ->
          assert is_integer(value), "#{resource}.#{field} is not an integer"

        field in Map.fetch!(@boolean_fields, resource) ->
          assert is_boolean(value), "#{resource}.#{field} is not a boolean"

        {resource, field} == {"assignments", "files"} ->
          assert Enum.all?(value, &is_binary/1)

        {resource, field} == {"decision requests", "options"} ->
          assert Enum.all?(value, fn option ->
                   Map.keys(option) == ["label"] and is_binary(option["label"])
                 end)

        {resource, field} == {"decision requests", "context"} ->
          assert_json_value(value)

        {resource, field} == {"sessions", "overrides"} ->
          assert Map.keys(value) |> Enum.sort() == ~w(guidanceExtra skillsAdd)
          assert Enum.all?(value["skillsAdd"], &is_binary/1)
          assert is_nil(value["guidanceExtra"]) or is_binary(value["guidanceExtra"])

        true ->
          assert is_binary(value), "#{resource}.#{field} is not a string"
      end
    end
  end

  defp assert_json_value(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: :ok

  defp assert_json_value(nil), do: :ok
  defp assert_json_value(value) when is_list(value), do: Enum.each(value, &assert_json_value/1)

  defp assert_json_value(value) when is_map(value) do
    assert Enum.all?(value, fn {key, nested} ->
             is_binary(key) and assert_json_value(nested) == :ok
           end)

    :ok
  end

  defp assert_populated_contract("work items", item) do
    assert item["specRefSha256"] == String.duplicate("a", 64)
    assert item["isBug"] and item["createdContextKnown"]
    assert is_integer(item["createdInTurnSeq"])
    assert is_nil(item["createdBySession"])
    assert_opaque(item["title"])
    assert_opaque(item["failReason"])
  end

  defp assert_populated_contract("assignments", item) do
    assert item["holderRole"] == "coder:core-detail"
    assert item["holderFallback"]
    assert item["holderHarness"] == "claude"
    assert item["holderProvider"] == "anthropic"
    assert item["files"] == ["a-first.ex", "lib/tightbeam/wire/router.ex", "z-last.ex"]
    assert is_nil(item["outcome"])
    assert_opaque(item["subject"])
  end

  defp assert_populated_contract("wakes", item) do
    assert item["state"] == "fired"
    assert item["reresolve"] == "lineage"
    assert item["firedBy"] == "fallback"
    assert item["classElection"] == "sender"
    assert item["rumination"] and item["digest"] and item["summon"]
    assert_opaque(item["prompt"])
  end

  defp assert_populated_contract("turns", item) do
    assert item["roleFallback"] == "owner"
    assert item["status"] == "delivered"
    assert item["model"] == "fable"
    assert item["thinkingLevel"] == "medium"
    assert item["harness"] == "claude"
    assert is_nil(item["modelContext"])
    assert_opaque(item["prompt"])
    assert_opaque(item["error"])
  end

  defp assert_populated_contract("decision requests", item) do
    assert item["kind"] == "statute"
    assert item["status"] == "ruled"
    assert item["decision"] == "allow"
    assert item["options"] == [%{"label" => "deny \"雪\""}, %{"label" => "allow\nlater"}]
    assert item["context"]["z"]["snow"] == "雪"
    assert_opaque(item["question"])
    assert_opaque(item["rationale"])
  end

  defp assert_populated_contract("sessions", item) do
    assert item["adopted"]
    assert item["spawnedBy"] == item["sessionKey"]
    assert item["overrides"]["skillsAdd"] == ["zeta", "alpha", "snow-雪"]
    assert item["identityRevision"] == "rev-雪"
    assert_opaque(item["displayName"])
    assert_opaque(item["overrides"]["guidanceExtra"])
  end

  defp assert_populated_contract("devices", item) do
    assert item["platform"] == "linux-雪"
    assert item["model"] == "model-x"
    assert_opaque(item["claimedName"])
  end

  defp assert_populated_contract("artifacts", item) do
    assert item["contentSha256"] == String.duplicate("b", 64)
    assert item["recordedTurnEvidence"] == "session-concurrent"
    assert item["state"] == "archived"
    assert item["home"] == "/archive/雪"
    assert_opaque(item["description"])
  end

  defp assert_populated_contract("read markers", item), do: assert_opaque(item["marker"])

  defp assert_opaque(value) do
    assert value == "quote:\" snow:雪 newline:\n slash:\\end"
  end

  defp randomized_source(resource, row) do
    row =
      case resource do
        "sessions" ->
          update_in(row.overrides["skills_add"], &Enum.shuffle/1)

        "decision requests" ->
          Map.update!(row, :context, &shuffle_json_maps/1)

        _ ->
          row
      end

    row |> Map.to_list() |> Enum.shuffle() |> Map.new()
  end

  defp shuffle_json_maps(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {key, shuffle_json_maps(nested)} end)
    |> Enum.shuffle()
    |> Map.new()
  end

  defp shuffle_json_maps(value) when is_list(value), do: Enum.map(value, &shuffle_json_maps/1)
  defp shuffle_json_maps(value), do: value

  defp get(ctx, path, bearer \\ nil, headers \\ []) do
    Enum.reduce(headers, conn(:get, path), fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> put_req_header("authorization", "Bearer #{bearer || ctx.token}")
    |> Router.call(Router.init(ctx.opts))
  end

  defp traced_get(ctx, path, bearer) do
    flush_core_detail_trace()
    traced = %{ctx | opts: Keyword.put(ctx.opts, :core_detail_trace, self())}
    response = get(traced, path, bearer)
    {response, drain_core_detail_trace([])}
  end

  defp drain_core_detail_trace(events) do
    receive do
      {:core_detail_trace, event} -> drain_core_detail_trace([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp flush_core_detail_trace do
    _events = drain_core_detail_trace([])
    :ok
  end

  defp fixed_selection_trace(events) do
    Enum.flat_map(events, fn
      {:shared_lookup, resource, query} ->
        [{:shared_lookup, resource, query}]

      {:sql_query, sql, params} ->
        [{:sql_query, normalize_sql(sql), length(params)}]

      {:au4_visibility, resource} ->
        [{:au4_visibility, resource}]

      _ ->
        []
    end)
  end

  defp assert_trace(events, row, outcome) do
    assert Enum.count(events, &match?({:shared_lookup, _, _}, &1)) == 1
    assert Enum.count(events, &match?({:au4_visibility, _}, &1)) == 1
    assert Enum.any?(events, &match?({:sql_query, _, _}, &1)), inspect(events)
    assert {:shared_lookup, row.resource, query_name(row.resource)} in events
    assert {:au4_visibility, row.resource} in events
    assert_primary_selection(events, row.resource)

    case outcome do
      :success ->
        assert Enum.count(events, &match?({:serializer, _, _}, &1)) == 1
        assert Enum.count(events, &match?({:ordered_item_encoder, _}, &1)) == 1
        assert Enum.count(events, &match?({:envelope, _}, &1)) == 1

      :denied ->
        refute Enum.any?(events, &match?({:serializer, _, _}, &1))
        refute Enum.any?(events, &match?({:ordered_item_encoder, _}, &1))
        refute Enum.any?(events, &match?({:envelope, _}, &1))
    end
  end

  defp assert_primary_selection(events, resource) do
    marker = primary_selection_marker(resource)

    assert Enum.count(events, fn
             {:sql_query, sql, _params} -> String.contains?(normalize_sql(sql), marker)
             _ -> false
           end) == 1,
           inspect(events)
  end

  defp primary_selection_marker("work items"), do: "FROM work_items AS wi"
  defp primary_selection_marker("assignments"), do: "FROM assignments AS a"
  defp primary_selection_marker("wakes"), do: "FROM wakes"
  defp primary_selection_marker("turns"), do: "FROM turns AS t"
  defp primary_selection_marker("decision requests"), do: "FROM decision_requests"
  defp primary_selection_marker("sessions"), do: "FROM sessions"
  defp primary_selection_marker("devices"), do: "FROM devices d"
  defp primary_selection_marker("artifacts"), do: "FROM artifacts"
  defp primary_selection_marker("read markers"), do: "FROM read_markers"

  defp normalize_sql(sql), do: sql |> String.split() |> Enum.join(" ")

  defp operation_trace(events, resource) do
    for {:operation, ^resource, operation} <- events, do: operation
  end

  defp query_name("work items"), do: :query_work_item
  defp query_name("assignments"), do: :query_assignment
  defp query_name("wakes"), do: :query_wake
  defp query_name("turns"), do: :query_turn_by_seq
  defp query_name("decision requests"), do: :query_decision_request
  defp query_name("sessions"), do: :query_session
  defp query_name("devices"), do: :query_device
  defp query_name("artifacts"), do: :query_artifact
  defp query_name("read markers"), do: :query_read_marker

  defp query_case(ctx, %{resource: "work items", row: %{id: id}}, principal) do
    StateResources.query_work_item(ctx.db, id, %{
      principal: principal_tuple(principal),
      rest_principal: principal,
      params: %{}
    })
  end

  defp query_case(ctx, %{resource: "assignments", row: %{id: id}}, principal) do
    StateResources.query_assignment(ctx.db, id, %{
      principal: principal_tuple(principal),
      rest_principal: principal,
      params: %{}
    })
  end

  defp query_case(ctx, %{resource: "read markers", row: row}, principal) do
    StateResources.query_read_marker(ctx.db, %{key: row.scope_key, principal: principal}, %{})
  end

  defp query_case(ctx, row, principal) do
    apply(StateResources, query_name(row.resource), [
      ctx.db,
      %{key: route_key(row), principal: principal}
    ])
  end

  defp principal_tuple(%{kind: "user", id: id}), do: {:user, id}
  defp principal_tuple(%{kind: "session", id: id}), do: {:session, id}

  defp route_key(%{resource: "wakes", row: row}), do: row.wake_id
  defp route_key(%{resource: "turns", row: row}), do: row.seq
  defp route_key(%{resource: "decision requests", row: row}), do: row.id
  defp route_key(%{resource: "sessions", row: row}), do: row.session_key
  defp route_key(%{resource: "devices", row: row}), do: row.device_id || row["deviceId"]
  defp route_key(%{resource: "artifacts", row: row}), do: row.artifact_id

  defp unknown_path(%{resource: "turns"}), do: "/api/turns/9223372036854775807"

  defp unknown_path(%{path: path}) do
    path |> String.split("/") |> List.replace_at(-1, "__missing__") |> Enum.join("/")
  end

  defp string_key_variants(%{path: path}) do
    key = path |> String.split("/") |> List.last()
    prefix = String.replace_suffix(path, key, "")
    truncated = String.slice(key, 0, max(String.length(key) - 1, 1))

    changed_case =
      if String.upcase(key) == key, do: String.downcase(key), else: String.upcase(key)

    [truncated, changed_case, " #{key}", "#{key} ", "#{key}é", "#{key}é", "#{key}-other"]
    |> Enum.uniq()
    |> Enum.map(&(prefix <> URI.encode(&1)))
  end

  defp outsider_device(ctx) do
    Devices.add_user(ctx.db, "outsider", false)

    {:pending, _device} =
      Devices.pair(ctx.db, %{
        device_id: "outsider-device",
        claimed_name: "Outsider",
        platform: nil,
        model: nil
      })

    Devices.approve(ctx.db, "outsider-device", "outsider")
  end

  defp decision_kind_rows(ctx) do
    admin = %{kind: "user", id: "admin", is_admin: true}
    owner = %{kind: "user", id: "flynn", is_admin: false}
    session = %{kind: "session", id: ctx.admin_session.session_key, is_admin: false}
    denied = %{kind: "user", id: "outsider", is_admin: false}

    for %{kind: kind, row: row} <- decision_route_cases(ctx) do
      allowed =
        case kind do
          :statute -> [admin, owner]
          :effort -> [admin, session]
          :agent -> [admin, owner, session]
        end

      {Atom.to_string(kind), row, allowed, denied}
    end
  end

  defp decision_route_cases(ctx) do
    for kind <- [:statute, :effort, :agent] do
      id = Map.fetch!(ctx.decision_request_ids, kind)
      row = StateResources.query_decision_request(ctx.db, id)

      case_row(
        "decision requests",
        "/api/decision-requests/#{id}",
        "decision_request.opened",
        %{"decisionRequestId" => id},
        row,
        &StateResources.decision_request/1
      )
      |> Map.put(:kind, kind)
    end
  end

  defp timing_cases(ctx) do
    core_detail_cases(ctx) ++ Enum.drop(decision_route_cases(ctx), 1)
  end

  defp measure_same_404_pair(ctx, row, bearer) do
    seed = :erlang.phash2(row.resource, 1_000_000) + 1
    :rand.seed(:exsss, {seed, seed + 17, seed + 101})

    cohorts =
      Enum.flat_map(1..10_000, fn _pair ->
        if :rand.uniform(2) == 1,
          do: [:forbidden, :unknown],
          else: [:unknown, :forbidden]
      end)

    samples =
      cohorts
      |> Enum.reduce(%{forbidden: [], unknown: []}, fn cohort, samples ->
        path = if cohort == :forbidden, do: row.path, else: unknown_path(row)
        started_at = System.monotonic_time(:nanosecond)
        response = get(ctx, path, bearer)
        elapsed = System.monotonic_time(:nanosecond) - started_at
        assert_error(response, 404, row.resource, "not_found")
        Map.update!(samples, cohort, &[elapsed | &1])
      end)

    for percentile <- [50, 95] do
      forbidden = nearest_rank(samples.forbidden, percentile)
      unknown = nearest_rank(samples.unknown, percentile)
      delta = abs(forbidden - unknown) / min(forbidden, unknown) * 100

      IO.puts(
        "rest_core_detail_timing resource=#{row.resource} seed=#{seed} " <>
          "p#{percentile}=#{forbidden}/#{unknown} delta=#{Float.round(delta, 3)}%"
      )

      assert delta <= 5.0
    end

    row.resource
  end

  defp nearest_rank(samples, percentile) do
    ordered = Enum.sort(samples)
    rank = ceil(percentile / 100 * length(ordered))
    Enum.at(ordered, rank - 1)
  end

  defp start_change_server(ctx) do
    bandit =
      start_supervised!(
        {Bandit,
         plug: {Router, Router.init(ctx.opts)}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    {:ok, ws} = WS.connect("127.0.0.1", port, "/ws/changes?protocolVersion=1")
    :ok = WS.send_text(ws, JSON.encode!(%{"type" => "auth", "token" => ctx.token}))
    {:ok, {:text, auth}, ws} = WS.recv(ws, 2_000)
    assert %{"type" => "auth_result", "success" => true} = JSON.decode!(auth)

    :ok =
      WS.send_text(
        ws,
        JSON.encode!(%{
          "type" => "subscribe",
          "protocolVersion" => 1,
          "subscriptionId" => "core-detail-a6",
          "filters" => %{"classes" => Enum.map(core_detail_cases(ctx), & &1.class)}
        })
      )

    {:ok, {:text, ready}, ws} = WS.recv(ws, 2_000)
    assert %{"type" => "subscription_ready"} = JSON.decode!(ready)
    {port, ws}
  end

  defp committed_core_frames(ctx, port, ws) do
    work_call = firehose_call("work-item-create", nil, %{title: "Raw A6 work item"})
    work = WorkItems.__handle__(ctx.db, "work-item-create", work_call)
    {work_raw, ws} = receive_raw_change(ws, "work_item.created")

    work_frame =
      frame(ctx, port, work_raw, "work items", "/api/work-items/#{work.id}", %{
        "workItemId" => work.id
      })

    assignment_call =
      firehose_call("assign", ctx.admin_session.session_key, %{
        subject: "Raw A6 assignment",
        idempotency_key: nil,
        reviews_assignment_id: nil,
        work_item_id: work.id,
        files: ["lib/tightbeam/wire/router.ex"]
      })
      |> Map.merge(%{
        target_role: nil,
        role_fallback: false,
        supervision_interval_ms: 60_000
      })

    assignment = Assignments.__handle__(ctx.db, "assign", assignment_call)
    {assignment_raw, ws} = receive_raw_change(ws, "assignment.opened")

    assignment_frame =
      frame(ctx, port, assignment_raw, "assignments", "/api/assignments/#{assignment.id}", %{
        "assignmentId" => assignment.id
      })

    wake_call = firehose_call("wake", ctx.admin_session.session_key, %{prompt: "Raw A6 wake"})

    wake =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.admin_session.session_key,
        origin: "user:flynn",
        prompt: "Raw A6 wake",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: ctx.admin_session.session_key,
        work_item_id: work.id,
        assignment_id: assignment.id
      })

    :ok = Publisher.accepted(ctx.db, wake_call, wake)
    {wake_raw, ws} = receive_raw_change(ws, "wake.scheduled")

    wake_frame =
      frame(ctx, port, wake_raw, "wakes", "/api/wakes/#{wake.wake_id}", %{
        "wakeId" => wake.wake_id
      })

    {:ok, turn_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: ctx.admin_session.session_key,
        message_id: "raw-a6-message",
        origin: "user:flynn",
        prompt: "Raw A6 turn",
        assignment_id: assignment.id,
        job_ref: work.id
      })

    assert {:ok, %{seq: ^turn_seq}} =
             Ledger.claim_next(ctx.db, ctx.admin_session.session_key, "raw-a6-owner")

    {turn_raw, ws} = receive_raw_change(ws, "turn.started")

    turn_frame =
      frame(ctx, port, turn_raw, "turns", "/api/turns/#{turn_seq}", %{
        "turnSeq" => turn_seq
      })

    Org.create(ctx.db, %{
      session_key: "raw-a6-reader",
      display_name: "Raw A6 reader",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

    decision_call =
      firehose_call("ask", "raw-a6-reader", %{
        question: "Raw A6 decision?"
      })
      |> Map.merge(%{
        origin: "agent:#{ctx.admin_session.session_key}",
        principal: {:session, ctx.admin_session.session_key},
        transport_session_key: ctx.admin_session.session_key
      })

    decision = Escalation.ask(ctx.db, decision_call)
    {decision_raw, ws} = receive_raw_change(ws, "decision_request.opened")

    decision_frame =
      frame(
        ctx,
        port,
        decision_raw,
        "decision requests",
        "/api/decision-requests/#{decision.id}",
        %{"decisionRequestId" => decision.id}
      )

    session =
      Org.create(ctx.db, %{
        session_key: "raw-a6-session",
        display_name: "Raw A6 session",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    :ok = Publisher.accepted(ctx.db, firehose_call("spawn", session.session_key, %{}), session)
    {session_raw, ws} = receive_raw_change(ws, "session.spawned")

    session_frame =
      frame(ctx, port, session_raw, "sessions", "/api/sessions/#{session.session_key}", %{
        "sessionKey" => session.session_key
      })

    {:pending, _device} =
      Devices.pair(ctx.db, %{
        device_id: "raw-a6-device",
        claimed_name: "Raw A6 device",
        platform: "test",
        model: "fixture"
      })

    device_call = firehose_call("approve-device", nil, %{device_id: "raw-a6-device"})
    device = Devices.approve_with_firehose(ctx.db, "raw-a6-device", "flynn", device_call)
    {device_raw, ws} = receive_raw_change(ws, "device.approved")

    device_frame =
      frame(ctx, port, device_raw, "devices", "/api/devices/#{device.device_id}", %{
        "deviceId" => device.device_id
      })

    artifact_call =
      firehose_call("artifact-record", "raw-a6-session", %{
        kind: "report",
        title: "Raw A6 artifact",
        origin_path: "reports/raw-a6.md",
        work_item_id: work.id
      })
      |> Map.put(:principal, {:session, "raw-a6-session"})

    artifact = Artifacts.record(ctx.db, artifact_call)
    {artifact_raw, ws} = receive_raw_change(ws, "artifact.recorded")

    artifact_frame =
      frame(
        ctx,
        port,
        artifact_raw,
        "artifacts",
        "/api/artifacts/#{artifact.artifact_id}",
        %{"artifactId" => artifact.artifact_id}
      )

    marker_call = firehose_call("read-marker-set", nil, %{scope_key: "raw-a6-scope"})

    assert {:ok, true, marker} =
             ReadMarkers.set(ctx.db, "flynn", "raw-a6-scope", "raw-a6-cursor",
               firehose_call: marker_call
             )

    {marker_raw, ws} = receive_raw_change(ws, "read_marker.updated")

    marker_frame =
      frame(
        ctx,
        port,
        marker_raw,
        "read markers",
        "/api/read-markers/#{marker.scope_key}",
        %{"scopeKey" => marker.scope_key, "userId" => marker.user_id}
      )

    frames = [
      work_frame,
      assignment_frame,
      wake_frame,
      turn_frame,
      decision_frame,
      session_frame,
      device_frame,
      artifact_frame,
      marker_frame
    ]

    {frames, ws}
  end

  defp firehose_call(verb, session_key, params) do
    %{
      verb: verb,
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: session_key,
      params: params,
      firehose_in_txn: true,
      firehose_hub: Hub
    }
  end

  defp receive_raw_change(ws, class) do
    case WS.recv(ws, 2_000) do
      {:ok, {:text, raw}, ws} ->
        case JSON.decode!(raw) do
          %{"type" => "change", "class" => ^class} -> {raw, ws}
          %{"type" => "change"} -> receive_raw_change(ws, class)
          _other -> receive_raw_change(ws, class)
        end

      other ->
        flunk("change socket closed before #{class}: #{inspect(other)}")
    end
  end

  defp frame(ctx, port, raw, resource, path, source_refs) do
    notice = JSON.decode!(raw)
    {http_status, http_headers, http_body} = http_get(port, path, ctx.token)

    %{
      raw: raw,
      class: notice["class"],
      resource: resource,
      path: path,
      http_status: http_status,
      http_headers: http_headers,
      http_body: http_body,
      source_refs: source_refs
    }
  end

  defp assert_source_ref_values("work items", payload, refs),
    do: assert(payload["id"] == refs["workItemId"])

  defp assert_source_ref_values("assignments", payload, refs),
    do: assert(payload["id"] == refs["assignmentId"])

  defp assert_source_ref_values("wakes", payload, refs),
    do: assert(payload["wakeId"] == refs["wakeId"])

  defp assert_source_ref_values("turns", payload, refs),
    do: assert(payload["seq"] == refs["turnSeq"])

  defp assert_source_ref_values("decision requests", payload, refs),
    do: assert(payload["id"] == refs["decisionRequestId"])

  defp assert_source_ref_values("sessions", payload, refs),
    do: assert(payload["sessionKey"] == refs["sessionKey"])

  defp assert_source_ref_values("devices", payload, refs),
    do: assert(payload["deviceId"] == refs["deviceId"])

  defp assert_source_ref_values("artifacts", payload, refs),
    do: assert(payload["artifactId"] == refs["artifactId"])

  defp assert_source_ref_values("read markers", payload, refs) do
    assert payload["userId"] == refs["userId"]
    assert payload["scopeKey"] == refs["scopeKey"]
  end

  defp http_get(port, path, bearer) do
    url = String.to_charlist("http://127.0.0.1:#{port}#{path}")

    {:ok, {{_version, status, _reason}, headers, body}} =
      :httpc.request(
        :get,
        {url, [{~c"authorization", String.to_charlist("Bearer #{bearer}")}]},
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

  defp assert_ordered_fields(bytes, fields) do
    {_offset, count} =
      Enum.reduce(fields, {0, 0}, fn field, {offset, count} ->
        marker = JSON.encode!(field) <> ":"

        {relative, _length} =
          :binary.match(bytes, marker, scope: {offset, byte_size(bytes) - offset})

        {relative + byte_size(marker), count + 1}
      end)

    assert count == length(fields)
  end

  defp raw_json_value(bytes, key) do
    marker = JSON.encode!(key) <> ":"
    {start, _length} = :binary.match(bytes, marker)
    value_start = start + byte_size(marker)

    value_length =
      json_value_length(binary_part(bytes, value_start, byte_size(bytes) - value_start))

    binary_part(bytes, value_start, value_length)
  end

  defp json_value_length(<<open, rest::binary>>) when open in [?{, ?[] do
    close = if open == ?{, do: ?}, else: ?]
    json_composite_length(rest, open, close, 1, false, false, 1)
  end

  defp json_value_length(<<?\", rest::binary>>),
    do: json_string_length(rest, false, 1)

  defp json_value_length(bytes) do
    case :binary.match(bytes, [",", "}", "]"]) do
      {length, _} -> length
      :nomatch -> byte_size(bytes)
    end
  end

  defp json_composite_length(<<>>, _open, _close, _depth, _quoted, _escaped, length),
    do: length

  defp json_composite_length(<<byte, rest::binary>>, open, close, depth, quoted, escaped, length) do
    cond do
      quoted and escaped ->
        json_composite_length(rest, open, close, depth, true, false, length + 1)

      quoted and byte == ?\\ ->
        json_composite_length(rest, open, close, depth, true, true, length + 1)

      byte == ?\" ->
        json_composite_length(rest, open, close, depth, not quoted, false, length + 1)

      quoted ->
        json_composite_length(rest, open, close, depth, true, false, length + 1)

      byte == open ->
        json_composite_length(rest, open, close, depth + 1, false, false, length + 1)

      byte == close and depth == 1 ->
        length + 1

      byte == close ->
        json_composite_length(rest, open, close, depth - 1, false, false, length + 1)

      true ->
        json_composite_length(rest, open, close, depth, false, false, length + 1)
    end
  end

  defp json_string_length(<<>>, _escaped, length), do: length

  defp json_string_length(<<byte, rest::binary>>, escaped, length) do
    cond do
      escaped -> json_string_length(rest, false, length + 1)
      byte == ?\\ -> json_string_length(rest, true, length + 1)
      byte == ?\" -> length + 1
      true -> json_string_length(rest, false, length + 1)
    end
  end

  defp assert_error(response, status, resource, code, message \\ nil) do
    error =
      if message,
        do: ~s({"code":#{JSON.encode!(code)},"message":#{JSON.encode!(message)}}),
        else: ~s({"code":#{JSON.encode!(code)}})

    assert response.status == status

    assert response.resp_body ==
             ~s({"schemaVersion":1,"resource":#{JSON.encode!(resource)},"error":#{error}})
  end

  defp assert_application_headers(response) do
    assert response_application_headers(response) == %{
             "cache-control" => ["no-store"],
             "content-type" => ["application/json; charset=utf-8"]
           }

    for name <- ~w(etag vary location retry-after www-authenticate set-cookie) do
      assert get_resp_header(response, name) == []
    end
  end

  defp response_application_headers(response) do
    %{
      "cache-control" => get_resp_header(response, "cache-control"),
      "content-type" => get_resp_header(response, "content-type")
    }
  end
end
