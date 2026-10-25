defmodule Tightbeam.RestArtifactAttestRoutesTest do
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
    Schema,
    StateResources,
    WorkItems
  }

  alias Tightbeam.Firehose.Hub
  alias Tightbeam.Wire.Router

  setup do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-artifact-attest-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)
    :initialized = Identity.init!(base_dir)
    Archetypes.load!(base_dir)

    db = :"rest_artifact_attest_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({Hub, name: Hub})
    :ok = Schema.ensure_all(db)

    {:paired, admin_device} =
      claim_org(db, %{
        device_id: "artifact-attest-admin-device",
        claimed_name: "Flynn",
        platform: nil,
        model: nil
      })

    creator_session = ensure_main_session(db, "flynn")
    alice = create_user(db, "alice")
    bob = create_user(db, "bob")
    outsider = create_user(db, "outsider")

    alice_item = create_work_item(db, "alice", "Alice-owned item")
    bob_item = create_work_item(db, "bob", "Bob-owned item")

    owner_assignment_id = "fixture-assignment-owner"
    opener_assignment_id = "fixture-assignment-opener"
    session_opener_assignment_id = "fixture-assignment-session-opener"
    hidden_assignment_id = "fixture-assignment-hidden"

    insert_assignment(db, owner_assignment_id, bob.session.session_key, "bob", alice_item.id)
    insert_assignment(db, opener_assignment_id, bob.session.session_key, "alice", bob_item.id)

    insert_session_opened_assignment(
      db,
      session_opener_assignment_id,
      bob.session.session_key,
      alice.session.session_key,
      bob_item.id
    )

    insert_assignment(db, hidden_assignment_id, bob.session.session_key, "bob", bob_item.id)

    owner_attests = [
      insert_attest(
        db,
        "fixture-attest-owner-1",
        owner_assignment_id,
        bob.session.session_key,
        100
      ),
      insert_attest(
        db,
        "fixture-attest-owner-2",
        owner_assignment_id,
        bob.session.session_key,
        200
      )
    ]

    opener_attest =
      insert_attest(
        db,
        "fixture-attest-opener-1",
        opener_assignment_id,
        bob.session.session_key,
        300
      )

    _session_opener_attest =
      insert_attest(
        db,
        "fixture-attest-session-opener-1",
        session_opener_assignment_id,
        bob.session.session_key,
        350
      )

    _hidden_attest =
      insert_attest(
        db,
        "fixture-attest-hidden-1",
        hidden_assignment_id,
        bob.session.session_key,
        400
      )

    owner_artifact =
      record_artifact(db, creator_session.session_key, alice_item.id, "report", "Owner artifact")

    second_owner_artifact =
      record_artifact(
        db,
        creator_session.session_key,
        alice_item.id,
        "doc",
        "Second owner artifact"
      )

    hidden_artifact =
      record_artifact(db, creator_session.session_key, bob_item.id, "report", "Hidden artifact")

    set_artifact_times(db, [owner_artifact, second_owner_artifact, hidden_artifact])

    opts = [
      db: db,
      base_dir: base_dir,
      handlers: %{},
      cli_token: "tbc_artifact_attest_routes",
      firehose_hub: Hub,
      model_catalog: %{},
      session_status: fn _ -> nil end
    ]

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{
      db: db,
      opts: opts,
      admin_device: admin_device,
      creator_session: creator_session,
      alice: alice,
      bob: bob,
      outsider: outsider,
      alice_item: alice_item,
      bob_item: bob_item,
      owner_assignment_id: owner_assignment_id,
      opener_assignment_id: opener_assignment_id,
      session_opener_assignment_id: session_opener_assignment_id,
      hidden_assignment_id: hidden_assignment_id,
      owner_attests: owner_attests,
      opener_attest: opener_attest,
      owner_artifact: owner_artifact,
      second_owner_artifact: second_owner_artifact,
      hidden_artifact: hidden_artifact
    }
  end

  test "artifact collection and detail share the canonical projection, filters, and tuple cursor",
       ctx do
    collection =
      get(
        ctx,
        "/api/artifacts?workItemId=#{ctx.alice_item.id}&createdBySession=#{ctx.creator_session.session_key}&limit=1",
        ctx.alice.device.token
      )

    assert collection.status == 200, collection.resp_body
    body = JSON.decode!(collection.resp_body)
    assert body["resource"] == "artifacts"
    assert length(body["items"]) == 1

    assert body["items"] == [
             StateResources.artifact(Artifacts.get(ctx.db, ctx.second_owner_artifact.artifact_id))
           ]

    assert body["page"]["hasMoreBefore"]

    older_page =
      get(
        ctx,
        "/api/artifacts?workItemId=#{ctx.alice_item.id}&createdBySession=#{ctx.creator_session.session_key}&limit=1&before=#{body["page"]["oldestCursor"]}",
        ctx.alice.device.token
      )

    assert older_page.status == 200, older_page.resp_body

    assert JSON.decode!(older_page.resp_body)["items"] == [
             StateResources.artifact(Artifacts.get(ctx.db, ctx.owner_artifact.artifact_id))
           ]

    filtered =
      get(
        ctx,
        "/api/artifacts?workItemId=#{ctx.alice_item.id}&state=in-workspace&kind=report",
        ctx.alice.device.token
      )

    assert filtered.status == 200, filtered.resp_body

    assert JSON.decode!(filtered.resp_body)["items"] == [
             StateResources.artifact(Artifacts.get(ctx.db, ctx.owner_artifact.artifact_id))
           ]

    repeated_kind_filter =
      get(
        ctx,
        "/api/artifacts?workItemId=#{ctx.alice_item.id}&kind=report&kind=doc",
        ctx.alice.device.token
      )

    assert repeated_kind_filter.status == 200
    assert length(JSON.decode!(repeated_kind_filter.resp_body)["items"]) == 2

    released =
      get(
        ctx,
        "/api/artifacts?workItemId=#{ctx.alice_item.id}&state=released&kind=doc",
        ctx.alice.device.token
      )

    assert released.status == 200

    assert JSON.decode!(released.resp_body)["items"] == [
             StateResources.artifact(Artifacts.get(ctx.db, ctx.second_owner_artifact.artifact_id))
           ]

    invalid_state =
      get(ctx, "/api/artifacts?state=unknown", ctx.alice.device.token)

    assert invalid_state.status == 400

    detail =
      get(ctx, "/api/artifacts/#{ctx.owner_artifact.artifact_id}", ctx.alice.device.token)

    assert detail.status == 200, detail.resp_body

    assert JSON.decode!(detail.resp_body)["item"] ==
             StateResources.artifact(Artifacts.get(ctx.db, ctx.owner_artifact.artifact_id))

    hidden_collection =
      get(ctx, "/api/artifacts?workItemId=#{ctx.bob_item.id}", ctx.alice.device.token)

    assert hidden_collection.status == 200
    assert JSON.decode!(hidden_collection.resp_body)["items"] == []

    hidden_detail =
      get(ctx, "/api/artifacts/#{ctx.hidden_artifact.artifact_id}", ctx.alice.device.token)

    unknown_detail = get(ctx, "/api/artifacts/art_missing", ctx.alice.device.token)
    assert hidden_detail.status == 404
    assert hidden_detail.resp_body == unknown_detail.resp_body

    principal_mismatch =
      get(
        ctx,
        "/api/artifacts?workItemId=#{ctx.alice_item.id}&createdBySession=#{ctx.creator_session.session_key}&limit=1&before=#{body["page"]["oldestCursor"]}",
        ctx.bob.device.token
      )

    assert principal_mismatch.status == 404
    assert principal_mismatch.resp_body == unknown_detail.resp_body

    admin_collection = get(ctx, "/api/artifacts", ctx.admin_device.token)
    assert admin_collection.status == 200, admin_collection.resp_body
    assert length(JSON.decode!(admin_collection.resp_body)["items"]) == 3

    owner_session_collection =
      get(
        ctx,
        "/api/artifacts?workItemId=#{ctx.alice_item.id}",
        ctx.alice.session.cli_token
      )

    assert owner_session_collection.status == 200
    assert JSON.decode!(owner_session_collection.resp_body)["items"] == []

    creator_session_collection =
      get(
        ctx,
        "/api/artifacts?workItemId=#{ctx.bob_item.id}",
        ctx.creator_session.cli_token
      )

    assert creator_session_collection.status == 200

    assert JSON.decode!(creator_session_collection.resp_body)["items"] == [
             StateResources.artifact(Artifacts.get(ctx.db, ctx.hidden_artifact.artifact_id))
           ]
  end

  test "attest collection and nested reads authorize parents before filtering and paging", ctx do
    global =
      get(
        ctx,
        "/api/attests?workItemId=#{ctx.bob_item.id}&kind=progress&limit=1",
        ctx.alice.device.token
      )

    assert global.status == 200, global.resp_body
    global_body = JSON.decode!(global.resp_body)
    assert global_body["items"] == [StateResources.attest(ctx.opener_attest)]
    assert global_body["page"]["hasMoreBefore"] == false

    repeated_assignment_filter =
      get(
        ctx,
        "/api/attests?assignmentId=#{ctx.owner_assignment_id}&assignmentId=#{ctx.opener_assignment_id}",
        ctx.alice.device.token
      )

    assert repeated_assignment_filter.status == 200
    assert length(JSON.decode!(repeated_assignment_filter.resp_body)["items"]) == 3

    opener_nested =
      get(
        ctx,
        "/api/assignments/#{ctx.opener_assignment_id}/attests?kind=progress",
        ctx.alice.device.token
      )

    assert opener_nested.status == 200, opener_nested.resp_body

    assert JSON.decode!(opener_nested.resp_body)["items"] == [
             StateResources.attest(ctx.opener_attest)
           ]

    owner_nested =
      get(
        ctx,
        "/api/assignments/#{ctx.owner_assignment_id}/attests?limit=1",
        ctx.alice.device.token
      )

    assert owner_nested.status == 200, owner_nested.resp_body
    owner_body = JSON.decode!(owner_nested.resp_body)
    assert owner_body["items"] == [StateResources.attest(List.last(ctx.owner_attests))]
    assert owner_body["page"]["hasMoreBefore"]

    prior_owner_page =
      get(
        ctx,
        "/api/assignments/#{ctx.owner_assignment_id}/attests?limit=1&before=#{owner_body["page"]["oldestCursor"]}",
        ctx.alice.device.token
      )

    assert prior_owner_page.status == 200, prior_owner_page.resp_body

    assert JSON.decode!(prior_owner_page.resp_body)["items"] == [
             StateResources.attest(List.first(ctx.owner_attests))
           ]

    holder_nested =
      get(
        ctx,
        "/api/assignments/#{ctx.opener_assignment_id}/attests",
        ctx.bob.session.cli_token
      )

    assert holder_nested.status == 200, holder_nested.resp_body

    assert JSON.decode!(holder_nested.resp_body)["items"] == [
             StateResources.attest(ctx.opener_attest)
           ]

    session_collection =
      get(
        ctx,
        "/api/attests?assignmentId=#{ctx.owner_assignment_id}",
        ctx.alice.session.cli_token
      )

    assert session_collection.status == 200, session_collection.resp_body
    assert JSON.decode!(session_collection.resp_body)["items"] == []

    session_opener_nested =
      get(
        ctx,
        "/api/assignments/#{ctx.session_opener_assignment_id}/attests",
        ctx.alice.session.cli_token
      )

    assert session_opener_nested.status == 200, session_opener_nested.resp_body
    assert length(JSON.decode!(session_opener_nested.resp_body)["items"]) == 1

    forbidden_parent =
      get(
        ctx,
        "/api/assignments/#{ctx.hidden_assignment_id}/attests",
        ctx.alice.device.token
      )

    unknown_parent =
      get(ctx, "/api/assignments/unknown-assignment/attests", ctx.alice.device.token)

    assert forbidden_parent.status == 404
    assert forbidden_parent.resp_body == unknown_parent.resp_body

    session_forbidden_parent =
      get(
        ctx,
        "/api/assignments/#{ctx.owner_assignment_id}/attests",
        ctx.alice.session.cli_token
      )

    assert session_forbidden_parent.status == 404
    assert session_forbidden_parent.resp_body == unknown_parent.resp_body

    outsider_nested =
      get(
        ctx,
        "/api/assignments/#{ctx.opener_assignment_id}/attests",
        ctx.outsider.device.token
      )

    assert outsider_nested.status == 404
    assert outsider_nested.resp_body == unknown_parent.resp_body

    principal_mismatch =
      get(
        ctx,
        "/api/assignments/#{ctx.owner_assignment_id}/attests?limit=1&before=#{owner_body["page"]["oldestCursor"]}",
        ctx.bob.device.token
      )

    assert principal_mismatch.status == 404
    assert principal_mismatch.resp_body == unknown_parent.resp_body

    admin_collection = get(ctx, "/api/attests", ctx.admin_device.token)
    assert admin_collection.status == 200, admin_collection.resp_body
    assert length(JSON.decode!(admin_collection.resp_body)["items"]) == 5
  end

  defp create_user(db, user_id) do
    Devices.add_user(db, user_id, false)

    device_id = "#{user_id}-artifact-attest-device"

    {:pending, _pending} =
      Devices.pair(db, %{
        device_id: device_id,
        claimed_name: user_id,
        platform: nil,
        model: nil
      })

    %{device: Devices.approve(db, device_id, user_id), session: ensure_main_session(db, user_id)}
  end

  defp create_work_item(db, owner, title) do
    WorkItems.__handle__(db, "work-item-create", %{
      verb: "work-item-create",
      origin: "user:#{owner}",
      principal: {:user, owner},
      session_key: nil,
      params: %{title: title}
    })
  end

  defp insert_assignment(db, assignment_id, holder_session, opened_by_user, work_item_id) do
    {:ok, _rows} =
      DB.query(
        db,
        """
        INSERT INTO assignments
          (id, subject, holderKey, holderFallback, openedByUser, openedAt, state, workItemId)
        VALUES (?1, 'REST read fixture', ?2, 0, ?3, ?4, 'open', ?5)
        """,
        [
          assignment_id,
          holder_session,
          opened_by_user,
          System.system_time(:millisecond),
          work_item_id
        ]
      )

    assignment_id
  end

  defp insert_session_opened_assignment(
         db,
         assignment_id,
         holder_session,
         opened_by_session,
         work_item_id
       ) do
    {:ok, _rows} =
      DB.query(
        db,
        """
        INSERT INTO assignments
          (id, subject, holderKey, holderFallback, openedBySession, openedAt, state, workItemId)
        VALUES (?1, 'REST read fixture', ?2, 0, ?3, ?4, 'open', ?5)
        """,
        [
          assignment_id,
          holder_session,
          opened_by_session,
          System.system_time(:millisecond),
          work_item_id
        ]
      )

    assignment_id
  end

  defp insert_attest(db, attest_id, assignment_id, by_session, ts) do
    {:ok, _rows} =
      DB.query(
        db,
        """
        INSERT INTO attests (id, assignmentId, kind, note, bySession, ts)
        VALUES (?1, ?2, 'progress', 'REST read fixture', ?3, ?4)
        """,
        [attest_id, assignment_id, by_session, ts]
      )

    [row] = Assignments.list_attests(db, assignment_id) |> Enum.filter(&(&1.id == attest_id))
    row
  end

  defp record_artifact(db, session_key, work_item_id, kind, title) do
    Artifacts.record(db, %{
      principal: {:session, session_key},
      session_key: session_key,
      params: %{
        kind: kind,
        title: title,
        origin_path: "reports/#{String.replace(title, " ", "-")}.md",
        work_item_id: work_item_id
      }
    })
  end

  defp set_artifact_times(db, artifacts) do
    Enum.with_index(artifacts, 1)
    |> Enum.each(fn {artifact, created_at} ->
      {:ok, _rows} =
        DB.query(
          db,
          "UPDATE artifacts SET createdAt = ?2, updatedAt = ?2 WHERE artifactId = ?1",
          [artifact.artifact_id, created_at]
        )
    end)

    released = Enum.at(artifacts, 2)

    {:ok, _rows} =
      DB.query(db, "UPDATE artifacts SET state = 'released' WHERE artifactId = ?1", [
        released.artifact_id
      ])
  end

  defp get(ctx, path, bearer \\ nil) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{bearer || ctx.admin_device.token}")
    |> Router.call(Router.init(ctx.opts))
  end
end
