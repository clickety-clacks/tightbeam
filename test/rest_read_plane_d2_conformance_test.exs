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
    Identity,
    Wakes,
    WorkItems
  }

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

    flynn_device = approved_device(db, "d2-flynn-device", "Flynn", "flynn")
    outsider_device = approved_device(db, "d2-outsider-device", "Outsider", "outsider")
    admin_device = approved_device(db, "d2-admin-device", "Admin", "admin")

    flynn_session = ensure_main_session(db, "flynn")
    other_session = ensure_main_session(db, "other")
    admin_session = ensure_main_session(db, "admin")

    work_item = create_work_item(db, "flynn", "D2 artifact and attest reads")
    assignment = create_assignment(db, "flynn", flynn_session, work_item, "visible assignment")

    artifact = record_artifact(db, flynn_session, work_item, "report", "Visible report")
    artifact_doc = record_artifact(db, flynn_session, work_item, "doc", "Visible document")

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
    assert %{state: "released"} = Artifacts.release(ctx.db, ctx.artifact_doc.artifact_id)

    assert {:ok, _rows} =
             DB.query(
               ctx.db,
               "UPDATE artifacts SET createdAt=5000 WHERE artifactId IN (?1, ?2)",
               [ctx.artifact.artifact_id, ctx.artifact_doc.artifact_id]
             )

    filtered =
      get(
        ctx,
        "/api/artifacts?workItemId=#{ctx.work_item.id}&createdBySession=#{ctx.flynn_session.session_key}&kind=report&kind=doc&state=in-workspace&state=released"
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

    cross_principal =
      get(
        ctx,
        "/api/artifacts?workItemId=#{ctx.work_item.id}&limit=1&after=" <>
          URI.encode_www_form(cursor),
        ctx.flynn_session.cli_token
      )

    assert_error(cross_principal, 404, "artifacts", "not_found")

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

    assert JSON.decode!(admin_session.resp_body)["items"] == []
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

    cross_principal =
      get(
        ctx,
        base <> "?limit=2&before=" <> URI.encode_www_form(page["page"]["oldestCursor"]),
        ctx.flynn_session.cli_token
      )

    assert_error(cross_principal, 404, "attests", "not_found")

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

  defp record_artifact(db, session, work_item, kind, title) do
    Artifacts.record(db, %{
      principal: {:session, session.session_key},
      session_key: session.session_key,
      params: %{
        kind: kind,
        title: title,
        origin_path: "reports/#{String.replace(title, " ", "-")}.md",
        work_item_id: work_item.id
      }
    })
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
