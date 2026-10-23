defmodule Tightbeam.RestReadPlaneD2ConformanceTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{
    Archetypes,
    Artifacts,
    Assignments,
    DB,
    Devices,
    HarnessProcess,
    Identity,
    Wakes,
    WorkItems
  }

  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Hub
  alias Tightbeam.Wire.Router

  @artifact_fields ~w(
    artifactId kind title description createdBySession workItemId parentSession
    originPath contentSha256 recordedMessageId recordedTurnEvidence state home
    createdAt updatedAt rowVersion
  )
  @attest_fields ~w(
    id assignmentId kind verdictKind note bySession byUser producer producerCommand
    byHarness byProvider commitRefs ts rowVersion
  )
  @harness_process_fields ~w(id host harness pid state createdAt resolvedAt)

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-d2-read-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    :initialized = Identity.init!(base_dir)
    Archetypes.load!(base_dir)

    db = String.to_atom("d2_read_db_#{System.unique_integer([:positive])}")
    start_supervised!({DB, path: ":memory:", name: db})
    ensure_all_schemas(db)
    start_supervised!({Hub, name: Hub})

    Devices.add_user(db, "admin", true)
    Devices.add_user(db, "flynn", false)
    Devices.add_user(db, "other", false)
    Devices.add_user(db, "outsider", false)
    Devices.add_user(db, "docs", false)

    flynn_device = approved_device(db, "d2-flynn-device", "Flynn", "flynn")
    outsider_device = approved_device(db, "d2-outsider-device", "Outsider", "outsider")
    admin_device = approved_device(db, "d2-admin-device", "Admin", "admin")

    flynn_session = ensure_main_session(db, "flynn")
    other_session = ensure_main_session(db, "other")
    admin_session = ensure_main_session(db, "admin")
    docs_session = ensure_main_session(db, "docs")

    work_item = create_work_item(db, "flynn", "D2 artifact and attest reads")
    assignment = create_assignment(db, "flynn", flynn_session, work_item, "visible assignment")

    artifact = record_artifact(db, flynn_session, work_item, "report", "Visible report")

    artifact_doc =
      record_artifact(
        db,
        docs_session,
        work_item,
        "doc",
        "Visible document",
        "remote.example:/reports/Visible-document.md"
      )

    other_work_item = create_work_item(db, "other", "Other owner's item")

    other_work_item_artifact =
      record_artifact(db, flynn_session, other_work_item, "data", "Creator-only artifact")

    admin_work_item = create_work_item(db, "admin", "Administrator-owned item")

    admin_work_item_artifact =
      record_artifact(db, other_session, admin_work_item, "other", "Owner-only artifact")

    other_assignment =
      create_assignment(db, "other", other_session, other_work_item, "hidden assignment")

    second_assignment =
      create_assignment(db, "flynn", flynn_session, work_item, "second visible assignment")

    wake =
      Wakes.schedule(db, %{
        session_key: flynn_session.session_key,
        origin: "user:flynn",
        prompt: "D2 test wake",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: flynn_session.session_key,
        work_item_id: work_item.id,
        assignment_id: assignment.id
      })

    opts = [
      db: db,
      base_dir: base_dir,
      handlers: %{},
      cli_token: "tbc_d2_read",
      firehose_hub: Hub,
      session_status: fn _ -> nil end
    ]

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{
      db: db,
      opts: opts,
      token: flynn_device.token,
      outsider_token: outsider_device.token,
      admin_token: admin_device.token,
      flynn_session: flynn_session,
      other_session: other_session,
      admin_session: admin_session,
      docs_session: docs_session,
      work_item: work_item,
      assignment: assignment,
      second_assignment: second_assignment,
      other_assignment: other_assignment,
      artifact: artifact,
      artifact_doc: artifact_doc,
      other_work_item: other_work_item,
      other_work_item_artifact: other_work_item_artifact,
      admin_work_item_artifact: admin_work_item_artifact,
      wake: wake
    }
  end

  test "artifacts use canonical filters, visibility, keyset pages, and the closed public shape",
       ctx do
    assert :ok =
             Artifacts.archive_session(ctx.db, ctx.docs_session.session_key, nil, "/unused")

    assert %{state: "released"} = Artifacts.get(ctx.db, ctx.artifact_doc.artifact_id)

    assert {:ok, _rows} =
             DB.query(
               ctx.db,
               "UPDATE artifacts SET createdAt=5000 WHERE artifactId IN (?1, ?2)",
               [ctx.artifact.artifact_id, ctx.artifact_doc.artifact_id]
             )

    filtered =
      get(
        ctx,
        "/api/artifacts?workItemId=#{ctx.work_item.id}&createdBySession=#{ctx.flynn_session.session_key}&createdBySession=#{ctx.docs_session.session_key}&kind=report&kind=doc&state=in-workspace&state=released"
      )

    assert filtered.status == 200, filtered.resp_body
    decoded = JSON.decode!(filtered.resp_body)
    assert decoded["resource"] == "artifacts"
    refute Map.has_key?(decoded, "dependencyVersion")
    assert Enum.sort(Enum.map(decoded["items"], & &1["kind"])) == ["doc", "report"]

    assert Enum.map(decoded["items"], & &1["artifactId"]) ==
             Enum.sort([ctx.artifact.artifact_id, ctx.artifact_doc.artifact_id])

    assert Plug.Conn.get_resp_header(filtered, "cache-control") == ["no-store"]

    for item <- decoded["items"] do
      assert Enum.sort(Map.keys(item)) == Enum.sort(@artifact_fields)
      refute Map.has_key?(item, "producedByAssignmentId")
      refute Map.has_key?(item, "originHost")
      refute Map.has_key?(item, "originWorkspace")
    end

    released = get(ctx, "/api/artifacts?workItemId=#{ctx.work_item.id}&state=released")

    assert Enum.map(JSON.decode!(released.resp_body)["items"], & &1["artifactId"]) == [
             ctx.artifact_doc.artifact_id
           ]

    missing = get(ctx, "/api/artifacts?workItemId=wi_absent")
    assert missing.status == 200
    assert JSON.decode!(missing.resp_body)["items"] == []

    invalid_enum = get(ctx, "/api/artifacts?state=unknown")
    assert invalid_enum.status == 400
    assert JSON.decode!(invalid_enum.resp_body)["error"]["code"] == "invalid_filter"

    invalid_identity_state = get(ctx, "/api/artifacts?state=ready")
    assert_error(invalid_identity_state, 400, "artifacts", "invalid_filter")

    first = get(ctx, "/api/artifacts?workItemId=#{ctx.work_item.id}&limit=1&tail=false")
    assert first.status == 200
    first_page = JSON.decode!(first.resp_body)
    assert first_page["page"]["hasMoreAfter"]

    next_page =
      get(
        ctx,
        "/api/artifacts?workItemId=#{ctx.work_item.id}&limit=1&after=" <>
          URI.encode_www_form(first_page["page"]["newestCursor"])
      )

    assert next_page.status == 200
    assert JSON.decode!(next_page.resp_body)["page"]["hasMoreBefore"]

    cursor = first_page["page"]["newestCursor"]

    same_owner_session =
      get(
        ctx,
        "/api/artifacts?workItemId=#{ctx.work_item.id}&limit=1&after=" <>
          URI.encode_www_form(cursor),
        ctx.flynn_session.cli_token
      )

    assert same_owner_session.status == 200
    assert JSON.decode!(same_owner_session.resp_body) == JSON.decode!(next_page.resp_body)

    malformed_payload =
      cursor
      |> Base.url_decode64!(padding: false)
      |> JSON.decode!()
      |> Map.put("tuple", ["bad"])
      |> JSON.encode!()
      |> Base.url_encode64(padding: false)

    malformed_cross_principal =
      get(
        ctx,
        "/api/artifacts?workItemId=#{ctx.work_item.id}&limit=1&after=" <>
          URI.encode_www_form(malformed_payload),
        ctx.flynn_session.cli_token
      )

    assert_error(malformed_cross_principal, 400, "artifacts", "invalid_cursor")

    malformed = get(ctx, "/api/artifacts?after=not-a-cursor")
    assert_error(malformed, 400, "artifacts", "invalid_cursor")

    unlisted_filter = get(ctx, "/api/artifacts?originHost=host")
    assert_error(unlisted_filter, 400, "artifacts", "invalid_filter")

    visible_to_creator =
      get(ctx, "/api/artifacts?workItemId=#{ctx.other_work_item.id}", ctx.flynn_session.cli_token)

    assert Enum.map(JSON.decode!(visible_to_creator.resp_body)["items"], & &1["artifactId"]) == [
             ctx.other_work_item_artifact.artifact_id
           ]

    hidden_from_unlinked_user =
      get(ctx, "/api/artifacts?workItemId=#{ctx.other_work_item.id}", ctx.outsider_token)

    assert JSON.decode!(hidden_from_unlinked_user.resp_body)["items"] == []

    admin_user =
      get(
        ctx,
        "/api/artifacts?workItemId=#{ctx.admin_work_item_artifact.work_item_id}",
        ctx.admin_token
      )

    assert Enum.any?(JSON.decode!(admin_user.resp_body)["items"], fn item ->
             item["artifactId"] == ctx.admin_work_item_artifact.artifact_id
           end)

    admin_session =
      get(
        ctx,
        "/api/artifacts?workItemId=#{ctx.admin_work_item_artifact.work_item_id}",
        ctx.admin_session.cli_token
      )

    assert JSON.decode!(admin_session.resp_body)["items"] ==
             JSON.decode!(admin_user.resp_body)["items"]
  end

  test "assignment-attests bind the parent, filter before paging, and expose no private attest links",
       ctx do
    insert_attest(ctx, "att_d2_001", ctx.assignment.id, 1001, "progress", %{note: "first"})
    insert_attest(ctx, "att_d2_002", ctx.assignment.id, 1001, "progress", %{note: "second"})

    insert_attest(ctx, "att_d2_003", ctx.assignment.id, 1003, "verdict", %{
      verdict_kind: "reviewed-clean",
      note: "closed public verdict",
      by_session: nil,
      by_user: "flynn",
      producer: "test-producer",
      producer_command: "test-verify",
      by_harness: "codex",
      by_provider: "openai",
      commit_refs: [%{"repo" => "example/repo", "commit" => "0123456789abcdef"}],
      artifact_id: ctx.artifact.artifact_id,
      content_sha256: String.duplicate("a", 64),
      wait_id: ctx.wake.wake_id
    })

    base = "/api/assignments/#{ctx.assignment.id}/attests"
    latest = get(ctx, base <> "?limit=2")
    assert latest.status == 200, latest.resp_body
    page = JSON.decode!(latest.resp_body)
    assert Enum.map(page["items"], & &1["id"]) == ["att_d2_002", "att_d2_003"]
    assert page["page"]["hasMoreBefore"]
    assert page["resource"] == "attests"
    refute Map.has_key?(page, "dependencyVersion")
    assert Plug.Conn.get_resp_header(latest, "cache-control") == ["no-store"]

    verdict = get(ctx, base <> "?kind=verdict&verdictKind=reviewed-clean&byUser=absent")
    assert JSON.decode!(verdict.resp_body)["items"] == []

    verdict = get(ctx, base <> "?kind=verdict&verdictKind=reviewed-clean&byUser=flynn")
    [verdict_item] = JSON.decode!(verdict.resp_body)["items"]
    assert Enum.sort(Map.keys(verdict_item)) == Enum.sort(@attest_fields)
    assert verdict_item["rowVersion"] == 1003

    assert verdict_item["commitRefs"] == [
             %{"repo" => "example/repo", "commit" => "0123456789abcdef"}
           ]

    refute Map.has_key?(verdict_item, "artifactId")
    refute Map.has_key?(verdict_item, "contentSha256")
    refute Map.has_key?(verdict_item, "waitId")

    by_session = get(ctx, base <> "?bySession=#{ctx.flynn_session.session_key}")

    assert Enum.map(JSON.decode!(by_session.resp_body)["items"], & &1["id"]) == [
             "att_d2_001",
             "att_d2_002"
           ]

    invalid_kind = get(ctx, base <> "?kind=unknown")
    assert_error(invalid_kind, 400, "attests", "invalid_filter")

    unlisted_filter = get(ctx, base <> "?waitId=#{ctx.wake.wake_id}")
    assert_error(unlisted_filter, 400, "attests", "invalid_filter")

    repeated = get(ctx, base <> "?kind=progress&kind=verdict")
    assert length(JSON.decode!(repeated.resp_body)["items"]) == 3

    other_assignment_filter =
      get(ctx, base <> "?assignmentId=#{ctx.second_assignment.id}&workItemId=#{ctx.work_item.id}")

    assert JSON.decode!(other_assignment_filter.resp_body)["items"] == []

    before =
      get(
        ctx,
        base <> "?limit=2&before=" <> URI.encode_www_form(page["page"]["oldestCursor"])
      )

    assert Enum.map(JSON.decode!(before.resp_body)["items"], & &1["id"]) == ["att_d2_001"]

    parent_mismatch =
      get(
        ctx,
        "/api/assignments/#{ctx.second_assignment.id}/attests?before=" <>
          URI.encode_www_form(page["page"]["oldestCursor"])
      )

    assert_error(parent_mismatch, 400, "attests", "invalid_cursor")

    same_owner_session =
      get(
        ctx,
        base <> "?limit=2&before=" <> URI.encode_www_form(page["page"]["oldestCursor"]),
        ctx.flynn_session.cli_token
      )

    assert same_owner_session.status == 200

    assert Enum.map(JSON.decode!(same_owner_session.resp_body)["items"], & &1["id"]) ==
             Enum.map(JSON.decode!(before.resp_body)["items"], & &1["id"])

    malformed = get(ctx, base <> "?before=not-a-cursor")
    assert_error(malformed, 400, "attests", "invalid_cursor")

    insert_attest(ctx, "att_d2_hidden", ctx.other_assignment.id, 2000, "progress", %{
      note: "secret hidden child"
    })

    unknown_parent = get(ctx, "/api/assignments/asg_missing/attests")
    forbidden_parent = get(ctx, "/api/assignments/#{ctx.other_assignment.id}/attests")
    assert_error(unknown_parent, 404, "attests", "not_found")
    assert forbidden_parent.status == 404
    assert forbidden_parent.resp_body == unknown_parent.resp_body
    refute forbidden_parent.resp_body =~ "closed public verdict"
    refute forbidden_parent.resp_body =~ "secret hidden child"
    assert Plug.Conn.get_resp_header(forbidden_parent, "cache-control") == ["no-store"]
    assert Plug.Conn.get_resp_header(unknown_parent, "cache-control") == ["no-store"]
  end

  test "artifact pagination uses the default and clamped limits and survives deleted tuple neighbors",
       ctx do
    work_item = create_work_item(ctx.db, "flynn", "artifact pagination")
    prefix = "art_collection_page_"
    ids = page_ids(prefix, 0, 503)
    insert_artifact_rows(ctx, work_item.id, ctx.flynn_session.session_key, ids, 12_000)

    default_page = get(ctx, "/api/artifacts?workItemId=#{work_item.id}&tail=false")
    assert length(JSON.decode!(default_page.resp_body)["items"]) == 50

    first =
      get(ctx, "/api/artifacts?workItemId=#{work_item.id}&limit=501&tail=false")

    first_page = JSON.decode!(first.resp_body)
    assert first.status == 200
    assert length(first_page["items"]) == 500
    assert first_page["page"]["hasMoreAfter"]

    artifact_cursor =
      first_page["page"]["newestCursor"]
      |> Base.url_decode64!(padding: false)
      |> JSON.decode!()

    assert artifact_cursor["tuple"] == [12_000, Enum.at(ids, 499)]
    refute Map.has_key?(artifact_cursor, "rowid")
    refute Map.has_key?(artifact_cursor, "offset")
    refute Map.has_key?(artifact_cursor, "locator")

    rest =
      get(
        ctx,
        "/api/artifacts?workItemId=#{work_item.id}&after=" <>
          URI.encode_www_form(first_page["page"]["newestCursor"])
      )

    assert Enum.map(
             first_page["items"] ++ JSON.decode!(rest.resp_body)["items"],
             & &1["artifactId"]
           ) ==
             ids

    latest = get(ctx, "/api/artifacts?workItemId=#{work_item.id}&limit=501&tail=true")
    latest_page = JSON.decode!(latest.resp_body)
    assert latest_page["page"]["hasMoreBefore"]

    older =
      get(
        ctx,
        "/api/artifacts?workItemId=#{work_item.id}&before=" <>
          URI.encode_www_form(latest_page["page"]["oldestCursor"])
      )

    assert Enum.map(
             JSON.decode!(older.resp_body)["items"] ++ latest_page["items"],
             & &1["artifactId"]
           ) == ids

    boundary_page =
      get(ctx, "/api/artifacts?workItemId=#{work_item.id}&limit=2&tail=false")

    boundary_page = JSON.decode!(boundary_page.resp_body)
    assert Enum.map(boundary_page["items"], & &1["artifactId"]) == Enum.take(ids, 2)

    assert {:ok, _rows} =
             DB.query(ctx.db, "DELETE FROM artifacts WHERE artifactId IN (?1, ?2, ?3)", [
               Enum.at(ids, 0),
               Enum.at(ids, 1),
               Enum.at(ids, 2)
             ])

    after_deleted_boundary =
      get(
        ctx,
        "/api/artifacts?workItemId=#{work_item.id}&limit=2&after=" <>
          URI.encode_www_form(boundary_page["page"]["newestCursor"])
      )

    assert Enum.map(JSON.decode!(after_deleted_boundary.resp_body)["items"], & &1["artifactId"]) ==
             Enum.slice(ids, 3, 2)
  end

  test "artifact cursors reject changed filters and resources and omit a newly hidden boundary",
       ctx do
    work_item = create_work_item(ctx.db, "flynn", "artifact cursor precedence")
    ids = page_ids("art_collection_cursor_", 0, 3)
    insert_artifact_rows(ctx, work_item.id, ctx.docs_session.session_key, ids, 13_000)

    first =
      get(
        ctx,
        "/api/artifacts?workItemId=#{work_item.id}&kind=report&limit=1&tail=false"
      )

    cursor = JSON.decode!(first.resp_body)["page"]["newestCursor"]

    {changed_filter, changed_filter_events} =
      traced_get(
        ctx,
        "/api/artifacts?workItemId=#{work_item.id}&kind=doc&after=" <>
          URI.encode_www_form(cursor)
      )

    assert_error(changed_filter, 400, "artifacts", "invalid_cursor")
    refute Enum.any?(changed_filter_events, &match?({:sql_query, _, _}, &1))

    {wrong_resource, wrong_resource_events} =
      traced_get(
        ctx,
        "/api/assignments/#{ctx.assignment.id}/attests?after=" <>
          URI.encode_www_form(cursor)
      )

    assert_error(wrong_resource, 400, "attests", "invalid_cursor")
    refute Enum.any?(wrong_resource_events, &match?({:sql_query, _, _}, &1))

    {same_owner_session, _same_owner_events} =
      traced_get(
        ctx,
        "/api/artifacts?workItemId=#{work_item.id}&kind=report&after=" <>
          URI.encode_www_form(cursor),
        ctx.flynn_session.cli_token
      )

    assert same_owner_session.status == 200

    assert Enum.map(JSON.decode!(same_owner_session.resp_body)["items"], & &1["artifactId"]) ==
             Enum.drop(ids, 1)

    {malformed, malformed_events} =
      traced_get(ctx, "/api/artifacts?workItemId=#{work_item.id}&after=not-a-cursor")

    assert_error(malformed, 400, "artifacts", "invalid_cursor")
    refute Enum.any?(malformed_events, &match?({:sql_query, _, _}, &1))

    hidden_boundary =
      get(
        ctx,
        "/api/artifacts?workItemId=#{work_item.id}&limit=1&tail=false"
      )

    hidden_cursor = JSON.decode!(hidden_boundary.resp_body)["page"]["newestCursor"]

    assert {:ok, _rows} =
             DB.query(ctx.db, "UPDATE work_items SET ownerUserId='other' WHERE id=?1", [
               work_item.id
             ])

    now_hidden =
      get(
        ctx,
        "/api/artifacts?workItemId=#{work_item.id}&after=" <>
          URI.encode_www_form(hidden_cursor)
      )

    assert now_hidden.status == 200
    assert JSON.decode!(now_hidden.resp_body)["items"] == []
  end

  test "session artifact reads include rows outside the owner's user-token view",
       ctx do
    work_item = create_work_item(ctx.db, "other", "session artifact visibility")

    artifact =
      record_artifact(ctx.db, ctx.docs_session, work_item, "report", "Unlinked report")

    path = "/api/artifacts?workItemId=#{work_item.id}"

    session_read = get(ctx, path, ctx.flynn_session.cli_token)
    owner_user_read = get(ctx, path)

    assert Enum.map(JSON.decode!(session_read.resp_body)["items"], & &1["artifactId"]) == [
             artifact.artifact_id
           ]

    assert JSON.decode!(owner_user_read.resp_body)["items"] == []
  end

  test "assignment-attest pagination uses the default and clamped limits across deleted tuple neighbors",
       ctx do
    work_item = create_work_item(ctx.db, "flynn", "attest pagination")
    assignment = create_assignment(ctx.db, "flynn", ctx.flynn_session, work_item, "paged attests")
    prefix = "att_collection_page_"
    ids = page_ids(prefix, 0, 503)
    insert_attest_rows(ctx, assignment.id, ids, 14_000)
    path = "/api/assignments/#{assignment.id}/attests"

    default_page = get(ctx, path <> "?tail=false")
    assert length(JSON.decode!(default_page.resp_body)["items"]) == 50

    first = get(ctx, path <> "?limit=501&tail=false")
    first_page = JSON.decode!(first.resp_body)
    assert first.status == 200
    assert length(first_page["items"]) == 500
    assert first_page["page"]["hasMoreAfter"]

    attest_cursor =
      first_page["page"]["newestCursor"]
      |> Base.url_decode64!(padding: false)
      |> JSON.decode!()

    assert attest_cursor["tuple"] == [14_000, Enum.at(ids, 499)]
    refute Map.has_key?(attest_cursor, "rowid")
    refute Map.has_key?(attest_cursor, "offset")
    refute Map.has_key?(attest_cursor, "locator")

    rest =
      get(
        ctx,
        path <> "?after=" <> URI.encode_www_form(first_page["page"]["newestCursor"])
      )

    assert Enum.map(first_page["items"] ++ JSON.decode!(rest.resp_body)["items"], & &1["id"]) ==
             ids

    latest = get(ctx, path <> "?limit=501&tail=true")
    latest_page = JSON.decode!(latest.resp_body)
    assert latest_page["page"]["hasMoreBefore"]

    older =
      get(
        ctx,
        path <> "?before=" <> URI.encode_www_form(latest_page["page"]["oldestCursor"])
      )

    assert Enum.map(JSON.decode!(older.resp_body)["items"] ++ latest_page["items"], & &1["id"]) ==
             ids

    boundary_page = get(ctx, path <> "?limit=2&tail=false") |> then(&JSON.decode!(&1.resp_body))
    assert Enum.map(boundary_page["items"], & &1["id"]) == Enum.take(ids, 2)

    assert {:ok, _rows} =
             DB.query(ctx.db, "DELETE FROM attests WHERE id IN (?1, ?2, ?3)", [
               Enum.at(ids, 0),
               Enum.at(ids, 1),
               Enum.at(ids, 2)
             ])

    after_deleted_boundary =
      get(
        ctx,
        path <>
          "?limit=2&after=" <>
          URI.encode_www_form(boundary_page["page"]["newestCursor"])
      )

    assert Enum.map(JSON.decode!(after_deleted_boundary.resp_body)["items"], & &1["id"]) ==
             Enum.slice(ids, 3, 2)
  end

  test "nested attest collections use each session owner's read visibility",
       ctx do
    work_item = create_work_item(ctx.db, "other", "attest session visibility")

    assert %{deliveryOwnerSessionKey: owner_session_key} =
             WorkItems.__handle__(ctx.db, "work-item-update", %{
               verb: "work-item-update",
               origin: "user:other",
               principal: {:user, "other"},
               session_key: nil,
               params: %{
                 work_item_id: work_item.id,
                 delivery_owner_session_key: ctx.docs_session.session_key
               }
             })

    assert owner_session_key == ctx.docs_session.session_key

    holder_assignment =
      create_assignment(ctx.db, "other", ctx.flynn_session, work_item, "session holder")

    opener_assignment =
      create_session_opened_assignment(
        ctx.db,
        ctx.docs_session,
        ctx.other_session,
        work_item,
        "session opener"
      )

    insert_attest(ctx, "att_holder_session", holder_assignment.id, 15_001, "progress", %{})
    insert_attest(ctx, "att_opener_session", opener_assignment.id, 15_002, "progress", %{})

    holder_read =
      get(
        ctx,
        "/api/assignments/#{holder_assignment.id}/attests",
        ctx.flynn_session.cli_token
      )

    opener_read =
      get(
        ctx,
        "/api/assignments/#{opener_assignment.id}/attests",
        ctx.docs_session.cli_token
      )

    assert Enum.map(JSON.decode!(holder_read.resp_body)["items"], & &1["id"]) == [
             "att_holder_session"
           ]

    assert Enum.map(JSON.decode!(opener_read.resp_body)["items"], & &1["id"]) == [
             "att_opener_session"
           ]

    admin_user = get(ctx, "/api/assignments/#{holder_assignment.id}/attests", ctx.admin_token)

    admin_session =
      get(ctx, "/api/assignments/#{holder_assignment.id}/attests", ctx.admin_session.cli_token)

    assert Enum.map(JSON.decode!(admin_user.resp_body)["items"], & &1["id"]) == [
             "att_holder_session"
           ]

    assert admin_session.status == 200

    assert JSON.decode!(admin_session.resp_body)["items"] ==
             JSON.decode!(admin_user.resp_body)["items"]
  end

  test "collections use the shared query, visibility and item serializers",
       ctx do
    artifact_path =
      "/api/artifacts?workItemId=#{ctx.work_item.id}&createdBySession=#{ctx.flynn_session.session_key}"

    {artifact_collection, artifact_events} = traced_get(ctx, artifact_path)
    artifact = JSON.decode!(artifact_collection.resp_body)["items"] |> hd()

    {artifact_detail, detail_events} =
      traced_get(ctx, "/api/artifacts/#{ctx.artifact.artifact_id}")

    assert artifact_collection.status == 200
    assert JSON.decode!(artifact_detail.resp_body)["item"] == artifact
    assert Enum.sort(Map.keys(artifact)) == Enum.sort(@artifact_fields)
    assert {:shared_lookup, "artifacts", :query_artifact} in artifact_events
    assert {:au4_visibility, "artifacts"} in artifact_events
    assert {:serializer, "artifacts", :artifact} in artifact_events
    assert Enum.count(artifact_events, &match?({:serializer, "artifacts", _}, &1)) == 1
    assert {:shared_lookup, "artifacts", :query_artifact} in detail_events
    assert {:au4_visibility, "artifacts"} in detail_events
    assert {:serializer, "artifacts", :artifact} in detail_events
    assert Enum.any?(artifact_events, &match?({:sql_query, _, _}, &1))

    insert_attest(ctx, "att_collection_trace", ctx.assignment.id, 16_001, "progress", %{})

    {attest_collection, attest_events} =
      traced_get(ctx, "/api/assignments/#{ctx.assignment.id}/attests")

    assert attest_collection.status == 200
    assert {:shared_lookup, "attests", :query_attest} in attest_events
    assert {:au4_visibility, "assignments"} in attest_events
    assert {:au4_visibility, "attests"} in attest_events
    assert {:serializer, "attests", :attest} in attest_events
    assert Enum.count(attest_events, &match?({:serializer, "attests", _}, &1)) == 1
  end

  test "HarnessProcesses collection follows the rev-5 launch-ledger contract", ctx do
    assert :ok = HarnessProcess.ensure_schema(ctx.db)
    insert_harness_process_rows(ctx)

    first = get(ctx, "/api/harness-processes?limit=2&tail=false", ctx.admin_token)
    assert first.status == 200, first.resp_body
    assert Plug.Conn.get_resp_header(first, "cache-control") == ["no-store"]

    first_page = JSON.decode!(first.resp_body)
    assert first_page["resource"] == "harness processes"
    assert Enum.map(first_page["items"], & &1["id"]) == ["launch-a", "launch-b"]
    assert Enum.sort(Map.keys(hd(first_page["items"]))) == Enum.sort(@harness_process_fields)

    assert first.resp_body =~
             ~s({"id":"launch-a","host":"fixture-node-a","harness":"codex","pid":null,"state":"launching","createdAt":1000,"resolvedAt":null})

    assert hd(first_page["items"]) == %{
             "id" => "launch-a",
             "host" => "fixture-node-a",
             "harness" => "codex",
             "pid" => nil,
             "state" => "launching",
             "createdAt" => 1_000,
             "resolvedAt" => nil
           }

    assert Enum.map(first_page["items"], & &1["state"]) == ["launching", "running"]

    assert first_page["page"]["hasMoreAfter"]

    cursor_payload =
      first_page["page"]["newestCursor"]
      |> Base.url_decode64!(padding: false)
      |> JSON.decode!()

    assert cursor_payload["tuple"] == [1_000, "launch-b"]

    second =
      get(
        ctx,
        "/api/harness-processes?limit=2&after=" <>
          URI.encode_www_form(first_page["page"]["newestCursor"]),
        ctx.admin_token
      )

    assert second.status == 200, second.resp_body
    second_page = JSON.decode!(second.resp_body)
    assert second_page["page"]["hasMoreBefore"]
    assert second_page["page"]["hasMoreAfter"]
    assert Enum.map(second_page["items"], & &1["id"]) == ["launch-c", "launch-d"]

    third =
      get(
        ctx,
        "/api/harness-processes?limit=2&after=" <>
          URI.encode_www_form(second_page["page"]["newestCursor"]),
        ctx.admin_token
      )

    assert third.status == 200, third.resp_body
    third_page = JSON.decode!(third.resp_body)
    assert third_page["page"]["hasMoreBefore"]
    assert third_page["page"]["hasMoreAfter"]
    assert Enum.map(third_page["items"], & &1["id"]) == ["launch-e", "launch-f"]

    fourth =
      get(
        ctx,
        "/api/harness-processes?limit=2&after=" <>
          URI.encode_www_form(third_page["page"]["newestCursor"]),
        ctx.admin_token
      )

    assert fourth.status == 200, fourth.resp_body
    fourth_page = JSON.decode!(fourth.resp_body)
    refute fourth_page["page"]["hasMoreAfter"]
    assert Enum.map(fourth_page["items"], & &1["id"]) == ["launch-g"]

    all_items =
      first_page["items"] ++ second_page["items"] ++ third_page["items"] ++ fourth_page["items"]

    item_ids = Enum.map(all_items, & &1["id"])
    assert item_ids == ~w(launch-a launch-b launch-c launch-d launch-e launch-f launch-g)

    assert Enum.map(all_items, & &1["state"]) == [
             "launching",
             "running",
             "park_requested",
             "kill_failed",
             "closed_gracefully",
             "killed",
             "exited"
           ]

    assert Enum.at(all_items, 4)["resolvedAt"] == 4_000
    assert Enum.at(all_items, 0)["resolvedAt"] == nil

    host_filter = get(ctx, "/api/harness-processes?host=fixture-node-a", ctx.admin_token)

    assert Enum.map(JSON.decode!(host_filter.resp_body)["items"], & &1["id"]) == [
             "launch-a",
             "launch-b",
             "launch-c"
           ]

    harness_filter = get(ctx, "/api/harness-processes?harness=claude", ctx.admin_token)

    assert Enum.map(JSON.decode!(harness_filter.resp_body)["items"], & &1["id"]) == [
             "launch-c",
             "launch-e",
             "launch-f"
           ]

    state_filter = get(ctx, "/api/harness-processes?state=kill_failed", ctx.admin_token)
    assert Enum.map(JSON.decode!(state_filter.resp_body)["items"], & &1["id"]) == ["launch-d"]

    combined_filter =
      get(
        ctx,
        "/api/harness-processes?host=fixture-node-b&harness=claude&state=closed_gracefully",
        ctx.admin_token
      )

    assert Enum.map(JSON.decode!(combined_filter.resp_body)["items"], & &1["id"]) == [
             "launch-e"
           ]

    assert_error(
      get(ctx, "/api/harness-processes?state=unknown", ctx.admin_token),
      400,
      "harness processes",
      "invalid_filter"
    )

    for unsupported <- ~w(sessionKey provider model) do
      assert_error(
        get(ctx, "/api/harness-processes?#{unsupported}=fixture-value", ctx.admin_token),
        400,
        "harness processes",
        "invalid_filter"
      )
    end

    non_admin = get(ctx, "/api/harness-processes", ctx.token)
    assert non_admin.status == 200, non_admin.resp_body
    assert JSON.decode!(non_admin.resp_body)["items"] == []

    response_bytes = first.resp_body <> second.resp_body <> third.resp_body <> fourth.resp_body

    for excluded <- [
          "fixture-adapter-key",
          "fixture-preset",
          "fixture-ssh-destination",
          "/fixture/private-helper",
          "/fixture/private-identity",
          "fixture-boot-identity",
          "fixture-identity-token",
          "fixture-last-error",
          "fixture-preparation-boot",
          "98765"
        ] do
      refute response_bytes =~ excluded
    end
  end

  test "collection routing reuses the shared cursor and public serialization seams" do
    router = File.read!("lib/tightbeam/wire/router.ex")
    resources = File.read!("lib/tightbeam/state_resources.ex")

    assert router =~ "d1_boundary(request, principal, spec, conn)"
    assert router =~ "StateResources.query_artifact"
    assert router =~ "StateResources.query_attest"
    assert router =~ "StateResources.artifact(row)"
    assert router =~ "StateResources.attest(row)"
    assert router =~ "d1_collection_envelope(spec, items, page)"
    assert resources =~ "\"artifacts\" =>"
    assert resources =~ "\"attests\" =>"
    refute router =~ "defp artifact_item"
    refute router =~ "defp attest_item"
    refute router =~ "defp d2_cursor"
    refute router =~ "defp d2_collection_envelope"
    refute router =~ "defp artifact_visible?"
    refute router =~ "defp attest_visible?"
  end

  defp approved_device(db, device_id, name, user_id) do
    {:pending, _device} =
      Devices.pair(db, %{
        device_id: device_id,
        claimed_name: name,
        platform: nil,
        model: nil
      })

    Devices.approve(db, device_id, user_id)
  end

  defp create_work_item(db, user_id, title) do
    WorkItems.__handle__(db, "work-item-create", %{
      verb: "work-item-create",
      origin: "user:#{user_id}",
      principal: {:user, user_id},
      session_key: nil,
      params: %{title: title}
    })
  end

  defp create_assignment(db, user_id, session, work_item, subject) do
    Assignments.__handle__(db, "assign", %{
      verb: "assign",
      origin: "user:#{user_id}",
      principal: {:user, user_id},
      session_key: session.session_key,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 60_000,
      params: %{
        subject: subject,
        idempotency_key: nil,
        reviews_assignment_id: nil,
        work_item_id: work_item.id,
        files: ["lib/tightbeam/wire/router.ex"]
      }
    })
  end

  defp record_artifact(db, session, work_item, kind, title, origin_path \\ nil) do
    Artifacts.record(db, %{
      principal: {:session, session.session_key},
      session_key: session.session_key,
      params: %{
        kind: kind,
        title: title,
        origin_path: origin_path || "reports/#{String.replace(title, " ", "-")}.md",
        work_item_id: work_item.id
      }
    })
  end

  defp insert_artifact_rows(ctx, work_item_id, session_key, ids, created_at) do
    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Enum.each(ids, fn id ->
                 Txn.q(
                   txn,
                   """
                   INSERT INTO artifacts
                     (artifactId, kind, title, createdBySession, workItemId, parentSession,
                      originPath, createdAt, updatedAt)
                   VALUES (?1, 'report', ?2, ?3, ?4, ?3, ?5, ?6, ?6)
                   """,
                   [
                     id,
                     "Page row #{id}",
                     session_key,
                     work_item_id,
                     "reports/#{id}.md",
                     created_at
                   ]
                 )

                 Txn.q(
                   txn,
                   "INSERT INTO artifact_version_floors (artifactId, rowVersion) VALUES (?1, 1)",
                   [id]
                 )
               end)

               :ok
             end)
  end

  defp insert_attest_rows(ctx, assignment_id, ids, ts) do
    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Enum.each(ids, fn id ->
                 Txn.q(
                   txn,
                   "INSERT INTO attests (id, assignmentId, kind, bySession, ts) VALUES (?1, ?2, 'progress', ?3, ?4)",
                   [id, assignment_id, ctx.flynn_session.session_key, ts]
                 )
               end)

               :ok
             end)
  end

  defp insert_harness_process_rows(ctx) do
    rows = [
      {"launch-a", "fixture-node-a", "codex", 1, nil, "launching", 1_000, nil},
      {"launch-b", "fixture-node-a", "codex", 2, 101, "running", 1_000, nil},
      {"launch-c", "fixture-node-a", "claude", 3, 102, "park_requested", 1_000, nil},
      {"launch-d", "fixture-node-b", "codex", 4, 103, "kill_failed", 3_000, nil},
      {"launch-e", "fixture-node-b", "claude", 5, 104, "closed_gracefully", 4_000, 4_000},
      {"launch-f", "fixture-node-c", "claude", 6, 105, "killed", 5_000, 5_000},
      {"launch-g", "fixture-node-c", "codex", 7, 106, "exited", 6_000, 6_000}
    ]

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Enum.each(rows, fn {id, host, harness, sequence, pid, state, created, resolved} ->
                 Txn.q(
                   txn,
                   """
                   INSERT INTO harness_processes
                     (launchId, adapterKey, harness, preset, host, ssh, helperPath, identityPath,
                      launchSequence, osPid, processGroupId, bootIdentity, identityToken, state,
                      createdAt, resolvedAt, parkRequestedAt, killAttemptedAt, killSentAt,
                      lastError, preparationBootIdentity)
                   VALUES (?1, 'fixture-adapter-key', ?2, 'fixture-preset', ?3,
                           'fixture-ssh-destination', '/fixture/private-helper',
                           '/fixture/private-identity', ?4, ?5, 98765, 'fixture-boot-identity',
                           'fixture-identity-token', ?6, ?7, ?8, 111, 222, 333,
                           'fixture-last-error', 'fixture-preparation-boot')
                   """,
                   [id, harness, host, sequence, pid, state, created, resolved]
                 )
               end)

               :ok
             end)
  end

  defp create_session_opened_assignment(db, opener_session, holder_session, work_item, subject) do
    Assignments.__handle__(db, "assign", %{
      verb: "assign",
      origin: "session:#{opener_session.session_key}",
      principal: {:session, opener_session.session_key},
      session_key: holder_session.session_key,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 60_000,
      params: %{
        subject: subject,
        idempotency_key: nil,
        reviews_assignment_id: nil,
        work_item_id: work_item.id,
        files: ["lib/tightbeam/wire/router.ex"]
      }
    })
  end

  defp page_ids(prefix, first, count) do
    Enum.map(first..(first + count - 1), fn index ->
      prefix <> String.pad_leading(Integer.to_string(index), 4, "0")
    end)
  end

  defp traced_get(ctx, path, bearer \\ nil) do
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

  defp insert_attest(ctx, id, assignment_id, ts, kind, attrs) do
    verdict_kind = attrs[:verdict_kind]
    by_session = Map.get(attrs, :by_session, ctx.flynn_session.session_key)
    by_user = attrs[:by_user]
    commit_refs = if attrs[:commit_refs], do: JSON.encode!(attrs[:commit_refs]), else: nil

    assert {:ok, _rows} =
             DB.query(
               ctx.db,
               """
               INSERT INTO attests
                 (id, assignmentId, kind, verdictKind, note, bySession, byUser, producer,
                  producerCommand, byHarness, byProvider, commitRefs, artifactId,
                  contentSha256, waitId, ts)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
               """,
               [
                 id,
                 assignment_id,
                 kind,
                 verdict_kind,
                 attrs[:note],
                 by_session,
                 by_user,
                 attrs[:producer],
                 attrs[:producer_command],
                 attrs[:by_harness],
                 attrs[:by_provider],
                 commit_refs,
                 attrs[:artifact_id],
                 attrs[:content_sha256],
                 attrs[:wait_id],
                 ts
               ]
             )
  end

  defp get(ctx, path, bearer \\ nil) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{bearer || ctx.token}")
    |> Router.call(Router.init(ctx.opts))
  end

  defp assert_error(response, status, resource, code) do
    assert response.status == status

    assert response.resp_body ==
             ~s({"schemaVersion":1,"resource":"#{resource}","error":{"code":"#{code}"}})
  end
end
