defmodule Tightbeam.RestAttestsCollectionTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{Archetypes, Assignments, DB, Devices, Identity, WorkItems}
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

    reader_work_item = create_work_item(db, "reader", "Reader-owned item")
    other_work_item = create_work_item(db, "other", "Other-owned item")

    user_assignment =
      create_assignment(db, "reader", other_session, reader_work_item, "User-visible assignment")

    session_assignment =
      create_assignment(
        db,
        "other",
        reader_session,
        other_work_item,
        "Session-visible assignment"
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
      reader_work_item: reader_work_item,
      user_assignment: user_assignment,
      session_assignment: session_assignment,
      hidden_assignment: hidden_assignment
    }
  end

  test "top-level collection filters parent grants before keyset paging and projects the closed row",
       ctx do
    insert_attest(ctx, "test_attest_reader_050", ctx.user_assignment.id, 50)
    insert_attest(ctx, "test_attest_reader_100", ctx.user_assignment.id, 100)
    insert_attest(ctx, "test_attest_hidden_200", ctx.hidden_assignment.id, 200)
    insert_attest(ctx, "test_attest_reader_300", ctx.user_assignment.id, 300)
    insert_attest(ctx, "test_attest_session_150", ctx.session_assignment.id, 150)

    latest = get(ctx, "/api/attests?limit=2")
    assert latest.status == 200, latest.resp_body
    assert Plug.Conn.get_resp_header(latest, "cache-control") == ["no-store"]

    page = JSON.decode!(latest.resp_body)
    assert page["resource"] == "attests"

    assert Enum.map(page["items"], & &1["id"]) == [
             "test_attest_reader_100",
             "test_attest_reader_300"
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

    assert Enum.map(JSON.decode!(earlier.resp_body)["items"], & &1["id"]) == [
             "test_attest_reader_050"
           ]

    by_parent =
      get(
        ctx,
        "/api/attests?workItemId=#{ctx.reader_work_item.id}&kind=progress"
      )

    assert Enum.map(JSON.decode!(by_parent.resp_body)["items"], & &1["id"]) == [
             "test_attest_reader_050",
             "test_attest_reader_100",
             "test_attest_reader_300"
           ]

    missing = get(ctx, "/api/attests?assignmentId=unknown-assignment")
    assert JSON.decode!(missing.resp_body)["items"] == []
    assert_error(get(ctx, "/api/attests?kind=unknown-kind"), 400, "attests", "invalid_filter")

    session_rows = get(ctx, "/api/attests", ctx.reader_session.cli_token)

    assert Enum.map(JSON.decode!(session_rows.resp_body)["items"], & &1["id"]) == [
             "test_attest_session_150"
           ]

    mismatched_principal =
      get(
        ctx,
        "/api/attests?before=" <> URI.encode_www_form(page["page"]["oldestCursor"]),
        ctx.reader_session.cli_token
      )

    assert_error(mismatched_principal, 404, "attests", "not_found")

    admin_rows = get(ctx, "/api/attests?limit=20", ctx.admin_token)
    assert length(JSON.decode!(admin_rows.resp_body)["items"]) == 5
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

  defp insert_attest(ctx, id, assignment_id, ts) do
    assert {:ok, _rows} =
             DB.query(
               ctx.db,
               """
               INSERT INTO attests
                 (id, assignmentId, kind, verdictKind, note, bySession, byUser, producer,
                  producerCommand, byHarness, byProvider, commitRefs, artifactId,
                  contentSha256, waitId, ts)
               VALUES (?1, ?2, 'progress', NULL, ?3, ?4, NULL, NULL, NULL, NULL, NULL, NULL, ?5, ?6, NULL, ?7)
               """,
               [
                 id,
                 assignment_id,
                 "note for #{id}",
                 ctx.other_session.session_key,
                 nil,
                 nil,
                 ts
               ]
             )
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
