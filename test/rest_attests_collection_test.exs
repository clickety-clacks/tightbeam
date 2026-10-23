defmodule Tightbeam.RestAttestsCollectionTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{Archetypes, Assignments, DB, Devices, Identity, WorkItems}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Hub
  alias Tightbeam.Wire.Router

  @attest_fields ~w(
    id assignmentId kind verdictKind note bySession byUser producer producerCommand
    byHarness byProvider commitRefs ts rowVersion
  )

  setup do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-attest-collection-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)
    :initialized = Identity.init!(base_dir)
    Archetypes.load!(base_dir)

    db = String.to_atom("attest_collection_db_#{System.unique_integer([:positive])}")
    start_supervised!({DB, path: ":memory:", name: db})
    ensure_all_schemas(db)
    start_supervised!({Hub, name: Hub})

    Devices.add_user(db, "bootstrap-admin", true)
    Devices.add_user(db, "reader", false)
    Devices.add_user(db, "other", false)
    Devices.add_user(db, "admin", true)

    reader_device = approved_device(db, "attest-reader-device", "Reader", "reader")
    admin_device = approved_device(db, "attest-admin-device", "Admin", "admin")

    reader_session = ensure_main_session(db, "reader")
    other_session = ensure_main_session(db, "other")
    admin_session = ensure_main_session(db, "bootstrap-admin")

    reader_work_item = create_work_item(db, "reader", "Reader-owned item")
    other_work_item = create_work_item(db, "other", "Other-owned item")
    set_delivery_owner(db, "reader", reader_work_item, other_session)
    set_delivery_owner(db, "other", other_work_item, reader_session)

    opener_assignment =
      create_assignment(db, "reader", other_session, other_work_item, "User opener grant")

    owner_assignment =
      create_assignment(
        db,
        "other",
        other_session,
        reader_work_item,
        "User owner grant"
      )

    holder_assignment =
      create_assignment(db, "other", reader_session, other_work_item, "Session holder grant")

    session_opener_assignment =
      create_attests_session_opened_assignment(
        db,
        reader_session,
        other_session,
        other_work_item,
        "Session opener grant"
      )

    hidden_assignment =
      create_assignment(db, "other", other_session, other_work_item, "Hidden assignment")

    opts = [
      db: db,
      base_dir: base_dir,
      handlers: %{},
      cli_token: "tbc_attest_collection",
      firehose_hub: Hub,
      session_status: fn _ -> nil end
    ]

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{
      db: db,
      opts: opts,
      reader_token: reader_device.token,
      admin_token: admin_device.token,
      reader_session: reader_session,
      other_session: other_session,
      admin_session: admin_session,
      reader_work_item: reader_work_item,
      other_work_item: other_work_item,
      opener_assignment: opener_assignment,
      owner_assignment: owner_assignment,
      holder_assignment: holder_assignment,
      session_opener_assignment: session_opener_assignment,
      hidden_assignment: hidden_assignment
    }
  end

  test "top-level collection filters parent grants before keyset paging and projects the closed row",
       ctx do
    insert_attest(ctx, "test_attest_opener_050", ctx.opener_assignment.id, 50)
    insert_attest(ctx, "test_attest_opener_100", ctx.opener_assignment.id, 100)
    insert_attest(ctx, "test_attest_owner_300", ctx.owner_assignment.id, 300)
    insert_attest(ctx, "test_attest_hidden_200", ctx.hidden_assignment.id, 200)
    insert_attest(ctx, "test_attest_holder_150", ctx.holder_assignment.id, 150)
    insert_attest(ctx, "test_attest_session_opener_175", ctx.session_opener_assignment.id, 175)

    latest = get(ctx, "/api/attests?limit=2")
    assert latest.status == 200, latest.resp_body
    assert Plug.Conn.get_resp_header(latest, "cache-control") == ["no-store"]

    page = JSON.decode!(latest.resp_body)
    assert page["resource"] == "attests"

    assert Enum.map(page["items"], & &1["id"]) == [
             "test_attest_opener_100",
             "test_attest_owner_300"
           ]

    assert page["page"]["hasMoreBefore"]
    refute page["page"]["hasMoreAfter"]
    assert Enum.sort(Map.keys(hd(page["items"]))) == Enum.sort(@attest_fields)
    assert hd(page["items"])["rowVersion"] == 100
    refute latest.resp_body =~ "artifactId"
    refute latest.resp_body =~ "contentSha256"
    refute latest.resp_body =~ "waitId"

    earlier =
      get(
        ctx,
        "/api/attests?limit=2&before=" <>
          URI.encode_www_form(page["page"]["oldestCursor"])
      )

    assert Enum.map(JSON.decode!(earlier.resp_body)["items"], & &1["id"]) ==
             ["test_attest_opener_050"]

    by_parent =
      get(
        ctx,
        "/api/attests?workItemId=#{ctx.reader_work_item.id}&kind=progress"
      )

    assert Enum.map(JSON.decode!(by_parent.resp_body)["items"], & &1["id"]) ==
             ["test_attest_owner_300"]

    missing = get(ctx, "/api/attests?assignmentId=unknown-assignment")
    assert JSON.decode!(missing.resp_body)["items"] == []
    assert_error(get(ctx, "/api/attests?kind=unknown-kind"), 400, "attests", "invalid_filter")

    expected_ids = [
      "test_attest_opener_050",
      "test_attest_opener_100",
      "test_attest_holder_150",
      "test_attest_session_opener_175",
      "test_attest_hidden_200",
      "test_attest_owner_300"
    ]

    session_rows = get(ctx, "/api/attests", ctx.reader_session.cli_token)

    assert Enum.map(JSON.decode!(session_rows.resp_body)["items"], & &1["id"]) |> Enum.sort() ==
             Enum.sort(expected_ids)

    admin_session_rows = get(ctx, "/api/attests", ctx.admin_session.cli_token)
    assert Enum.map(JSON.decode!(admin_session_rows.resp_body)["items"], & &1["id"])
           |> Enum.sort() ==
             Enum.sort(expected_ids)

    same_owner_session_cursor =
      get(
        ctx,
        "/api/attests?before=" <> URI.encode_www_form(page["page"]["oldestCursor"]),
        ctx.reader_session.cli_token
      )

    assert same_owner_session_cursor.status == 200

    assert Enum.map(JSON.decode!(same_owner_session_cursor.resp_body)["items"], & &1["id"]) ==
             ["test_attest_opener_050"]

    admin_rows = get(ctx, "/api/attests?limit=20", ctx.admin_token)
    assert length(JSON.decode!(admin_rows.resp_body)["items"]) == 6
  end

  test "top-level collection applies each listed filter and rejects unlisted keys", ctx do
    insert_attest(ctx, "test_attest_filter_progress", ctx.opener_assignment.id, 100, %{
      by_session: ctx.reader_session.session_key
    })

    insert_attest(ctx, "test_attest_filter_verdict_reader", ctx.opener_assignment.id, 200, %{
      kind: "verdict",
      verdict_kind: "reviewed-clean",
      by_user: "reader"
    })

    insert_attest(ctx, "test_attest_filter_verdict_other", ctx.opener_assignment.id, 300, %{
      kind: "verdict",
      verdict_kind: "changes-requested",
      by_user: "other"
    })

    assignment_rows =
      get(ctx, "/api/attests?assignmentId=#{ctx.opener_assignment.id}")
      |> then(&JSON.decode!(&1.resp_body)["items"])

    work_item_rows =
      get(ctx, "/api/attests?workItemId=#{ctx.other_work_item.id}")
      |> then(&JSON.decode!(&1.resp_body)["items"])

    assert Enum.map(assignment_rows, & &1["id"]) == [
             "test_attest_filter_progress",
             "test_attest_filter_verdict_reader",
             "test_attest_filter_verdict_other"
           ]

    assert Enum.map(work_item_rows, & &1["id"]) == Enum.map(assignment_rows, & &1["id"])

    assert Enum.map(
             JSON.decode!(get(ctx, "/api/attests?kind=progress").resp_body)["items"],
             & &1["id"]
           ) == ["test_attest_filter_progress"]

    assert Enum.map(
             JSON.decode!(get(ctx, "/api/attests?verdictKind=reviewed-clean").resp_body)["items"],
             & &1["id"]
           ) == ["test_attest_filter_verdict_reader"]

    assert Enum.map(
             JSON.decode!(
               get(ctx, "/api/attests?bySession=#{ctx.reader_session.session_key}").resp_body
             )["items"],
             & &1["id"]
           ) == ["test_attest_filter_progress"]

    assert Enum.map(
             JSON.decode!(get(ctx, "/api/attests?byUser=reader").resp_body)["items"],
             & &1["id"]
           ) == ["test_attest_filter_verdict_reader"]

    assert_error(get(ctx, "/api/attests?kind=unknown-kind"), 400, "attests", "invalid_filter")
    assert_error(get(ctx, "/api/attests?note=not-allowlisted"), 400, "attests", "invalid_filter")
  end

  test "top-level collection and detail use the shared attest query, visibility and serializer",
       ctx do
    id = "test_attest_route_trace"
    insert_attest(ctx, id, ctx.opener_assignment.id, 100)

    {collection, collection_events} =
      traced_attests_get(ctx, "/api/attests?assignmentId=#{ctx.opener_assignment.id}")

    item = JSON.decode!(collection.resp_body)["items"] |> hd()

    {detail, detail_events} = traced_attests_get(ctx, "/api/attests/#{id}")

    assert collection.status == 200
    assert detail.status == 200
    assert JSON.decode!(detail.resp_body)["item"] == item
    assert {:shared_lookup, "attests", :query_attests} in collection_events
    assert {:au4_visibility, "attests"} in collection_events
    assert {:serializer, "attests", :attest} in collection_events
    assert Enum.count(collection_events, &match?({:serializer, "attests", _}, &1)) == 1
    assert Enum.any?(collection_events, &match?({:sql_query, _, _}, &1))
    assert {:shared_lookup, "attests", :query_attest} in detail_events
    assert {:au4_visibility, "attests"} in detail_events
    assert {:serializer, "attests", :attest} in detail_events
    assert Enum.count(detail_events, &match?({:serializer, "attests", _}, &1)) == 1
  end

  test "top-level tuple pagination uses the complete tuple across tied and deleted rows", ctx do
    ids = attest_page_ids("test_attest_collection_page_", 0, 503)
    insert_attest_rows(ctx, ctx.owner_assignment.id, ids, 14_000)
    path = "/api/attests?assignmentId=#{ctx.owner_assignment.id}"

    default_page = get(ctx, path <> "&tail=false")
    assert length(JSON.decode!(default_page.resp_body)["items"]) == 50

    first = get(ctx, path <> "&limit=501&tail=false")
    first_page = JSON.decode!(first.resp_body)
    assert first.status == 200
    assert length(first_page["items"]) == 500
    assert first_page["page"]["hasMoreAfter"]

    cursor =
      first_page["page"]["newestCursor"]
      |> Base.url_decode64!(padding: false)
      |> JSON.decode!()

    assert cursor["tuple"] == [14_000, Enum.at(ids, 499)]
    refute Map.has_key?(cursor, "rowid")
    refute Map.has_key?(cursor, "offset")
    refute Map.has_key?(cursor, "locator")

    rest = get(ctx, path <> "&after=" <> URI.encode_www_form(first_page["page"]["newestCursor"]))

    assert Enum.map(first_page["items"] ++ JSON.decode!(rest.resp_body)["items"], & &1["id"]) ==
             ids

    latest = get(ctx, path <> "&limit=501&tail=true")
    latest_page = JSON.decode!(latest.resp_body)
    assert latest_page["page"]["hasMoreBefore"]

    older =
      get(ctx, path <> "&before=" <> URI.encode_www_form(latest_page["page"]["oldestCursor"]))

    assert Enum.map(JSON.decode!(older.resp_body)["items"] ++ latest_page["items"], & &1["id"]) ==
             ids

    boundary_page = get(ctx, path <> "&limit=2&tail=false") |> then(&JSON.decode!(&1.resp_body))
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
        path <> "&limit=2&after=" <> URI.encode_www_form(boundary_page["page"]["newestCursor"])
      )

    assert Enum.map(JSON.decode!(after_deleted_boundary.resp_body)["items"], & &1["id"]) ==
             Enum.slice(ids, 3, 2)
  end

  test "top-level cursors reject malformed, nested and changed-filter reuse but accept the owner's session",
       ctx do
    ids = attest_page_ids("test_attest_cursor_", 0, 3)
    insert_attest_rows(ctx, ctx.opener_assignment.id, ids, 15_000)
    top_level_path = "/api/attests?assignmentId=#{ctx.opener_assignment.id}&kind=progress"

    {malformed, malformed_events} = traced_attests_get(ctx, "/api/attests?after=not-a-cursor")
    assert_error(malformed, 400, "attests", "invalid_cursor")
    refute Enum.any?(malformed_events, &match?({:sql_query, _, _}, &1))

    {first, _first_events} = traced_attests_get(ctx, top_level_path <> "&limit=1&tail=false")
    cursor = JSON.decode!(first.resp_body)["page"]["newestCursor"]

    {changed_filter, changed_filter_events} =
      traced_attests_get(
        ctx,
        "/api/attests?assignmentId=#{ctx.opener_assignment.id}&kind=verdict&after=" <>
          URI.encode_www_form(cursor)
      )

    assert_error(changed_filter, 400, "attests", "invalid_cursor")
    refute Enum.any?(changed_filter_events, &match?({:sql_query, _, _}, &1))

    {same_owner_session, _same_owner_events} =
      traced_attests_get(
        ctx,
        top_level_path <> "&after=" <> URI.encode_www_form(cursor),
        ctx.reader_session.cli_token
      )

    assert same_owner_session.status == 200

    assert Enum.map(JSON.decode!(same_owner_session.resp_body)["items"], & &1["id"]) ==
             Enum.drop(ids, 1)

    {nested_page, _nested_events} =
      traced_attests_get(
        ctx,
        "/api/assignments/#{ctx.opener_assignment.id}/attests?limit=1&tail=false"
      )

    nested_cursor = JSON.decode!(nested_page.resp_body)["page"]["newestCursor"]

    {nested_replay, nested_replay_events} =
      traced_attests_get(
        ctx,
        "/api/attests?assignmentId=#{ctx.opener_assignment.id}&after=" <>
          URI.encode_www_form(nested_cursor)
      )

    assert_error(nested_replay, 400, "attests", "invalid_cursor")
    refute Enum.any?(nested_replay_events, &match?({:sql_query, _, _}, &1))
  end

  test "top-level paging omits a boundary attest after its parent grant becomes hidden", ctx do
    work_item = create_work_item(ctx.db, "reader", "Attest cursor visibility")
    set_delivery_owner(ctx.db, "reader", work_item, ctx.other_session)

    assignment =
      create_assignment(ctx.db, "other", ctx.other_session, work_item, "Owner-only grant")

    ids = attest_page_ids("test_attest_hidden_cursor_", 0, 3)
    insert_attest_rows(ctx, assignment.id, ids, 16_000)

    first =
      get(ctx, "/api/attests?assignmentId=#{assignment.id}&limit=1&tail=false")
      |> then(&JSON.decode!(&1.resp_body))

    assert Enum.map(first["items"], & &1["id"]) == [Enum.at(ids, 0)]

    assert {:ok, _rows} =
             DB.query(ctx.db, "UPDATE work_items SET ownerUserId='other' WHERE id=?1", [
               work_item.id
             ])

    now_hidden =
      get(
        ctx,
        "/api/attests?assignmentId=#{assignment.id}&after=" <>
          URI.encode_www_form(first["page"]["newestCursor"])
      )

    assert now_hidden.status == 200
    assert JSON.decode!(now_hidden.resp_body)["items"] == []
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

  defp set_delivery_owner(db, user_id, work_item, session) do
    assert %{deliveryOwnerSessionKey: owner_session_key} =
             WorkItems.__handle__(db, "work-item-update", %{
               verb: "work-item-update",
               origin: "user:#{user_id}",
               principal: {:user, user_id},
               session_key: nil,
               params: %{
                 work_item_id: work_item.id,
                 delivery_owner_session_key: session.session_key
               }
             })

    assert owner_session_key == session.session_key
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

  defp create_attests_session_opened_assignment(
         db,
         opener_session,
         holder_session,
         work_item,
         subject
       ) do
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

  defp insert_attest(ctx, id, assignment_id, ts, attrs \\ %{}) do
    kind = Map.get(attrs, :kind, "progress")
    verdict_kind = attrs[:verdict_kind]
    by_user = attrs[:by_user]

    by_session =
      Map.get(
        attrs,
        :by_session,
        if(kind == "verdict" and not is_nil(by_user),
          do: nil,
          else: ctx.other_session.session_key
        )
      )

    assert {:ok, _rows} =
             DB.query(
               ctx.db,
               """
               INSERT INTO attests
                 (id, assignmentId, kind, verdictKind, note, bySession, byUser, producer,
                  producerCommand, byHarness, byProvider, commitRefs, artifactId,
                  contentSha256, waitId, ts)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?8)
               """,
               [
                 id,
                 assignment_id,
                 kind,
                 verdict_kind,
                 "note for #{id}",
                 by_session,
                 by_user,
                 ts
               ]
             )
  end

  defp insert_attest_rows(ctx, assignment_id, ids, ts) do
    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Enum.each(ids, fn id ->
                 Txn.q(
                   txn,
                   "INSERT INTO attests (id, assignmentId, kind, bySession, ts) VALUES (?1, ?2, 'progress', ?3, ?4)",
                   [id, assignment_id, ctx.other_session.session_key, ts]
                 )
               end)

               :ok
             end)
  end

  defp attest_page_ids(prefix, first, count) do
    Enum.map(first..(first + count - 1), fn index ->
      prefix <> String.pad_leading(Integer.to_string(index), 4, "0")
    end)
  end

  defp traced_attests_get(ctx, path, bearer \\ nil) do
    flush_attest_trace()
    traced = %{ctx | opts: Keyword.put(ctx.opts, :core_detail_trace, self())}
    response = get(traced, path, bearer)
    {response, drain_attest_trace([])}
  end

  defp drain_attest_trace(events) do
    receive do
      {:core_detail_trace, event} -> drain_attest_trace([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp flush_attest_trace do
    _events = drain_attest_trace([])
    :ok
  end

  defp get(ctx, path, bearer \\ nil) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{bearer || ctx.reader_token}")
    |> Router.call(Router.init(ctx.opts))
  end

  defp assert_error(response, status, resource, code) do
    assert response.status == status

    assert response.resp_body ==
             ~s({"schemaVersion":1,"resource":"#{resource}","error":{"code":"#{code}"}})
  end
end
