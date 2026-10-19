defmodule Tightbeam.RestExecutionMapTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{Archetypes, DB, Devices, Identity, Ledger, Schema}
  alias Tightbeam.Firehose.Hub
  alias Tightbeam.Wire.Router

  @node_fields ~w(
    id title specRefName specRefSha256 state failReason bracket1Armed origin
    creationContext parent finishedAt assignments jobs attests startedAt
    closingAttests openDecisionRequests turns minds fanOut active sinceProgressMs
  )

  setup do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-execution-map-rest-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)
    :initialized = Identity.init!(base_dir)
    Archetypes.load!(base_dir)

    db = String.to_atom("execution_map_rest_db_#{System.unique_integer([:positive])}")
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)
    assert {:ok, _rows} = DB.query(db, "UPDATE causal_events_epoch SET at=1 WHERE id=0")
    start_supervised!({Hub, name: Hub})

    # The first user is elevated by the cold-start rule; seed it so owner is a regular user.
    Devices.add_user(db, "admin", true)
    Devices.add_user(db, "owner", false)
    Devices.add_user(db, "other", false)
    assert Devices.user(db, "owner").is_admin == false

    owner_device = approved_device(db, "execution-map-owner-device", "Owner", "owner")
    other_device = approved_device(db, "execution-map-other-device", "Other", "other")
    owner_session = ensure_main_session(db, "owner")
    other_session = ensure_main_session(db, "other")

    opts = [
      db: db,
      base_dir: base_dir,
      handlers: %{},
      cli_token: "tbc_execution_map_rest",
      firehose_hub: Hub,
      session_status: fn _ -> nil end
    ]

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{
      db: db,
      opts: opts,
      token: owner_device.token,
      other_token: other_device.token,
      owner_session: owner_session,
      other_session: other_session
    }
  end

  test "all four routes use the canonical node shape and filter hidden sources before linking",
       ctx do
    insert_work_item!(ctx.db, "wi_parent", "owner", 10_000,
      created_by_session: ctx.other_session.session_key
    )

    insert_work_item!(ctx.db, "wi_child", "owner", 20_000,
      created_by_session: ctx.owner_session.session_key
    )

    insert_work_item!(ctx.db, "wi_review_child", "owner", 30_000,
      created_by_session: ctx.owner_session.session_key
    )

    insert_assignment!(ctx.db, "asg_hidden_middle",
      opener_user: "other",
      holder: ctx.other_session.session_key,
      work_item_id: "wi_parent"
    )

    insert_assignment!(ctx.db, "asg_visible_review",
      opener_user: "other",
      holder: ctx.owner_session.session_key,
      reviews: "asg_hidden_middle"
    )

    {:ok, linked_turn_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: ctx.owner_session.session_key,
        message_id: "execution-map-hidden-parent",
        origin: "user:owner",
        prompt: "execution map hidden parent",
        job_ref: "wi_parent"
      })

    {:ok, review_turn_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: ctx.owner_session.session_key,
        message_id: "execution-map-hidden-hop",
        origin: "user:owner",
        prompt: "execution map hidden hop",
        assignment_id: "asg_visible_review"
      })

    set_creation_turn!(ctx.db, "wi_child", linked_turn_seq)
    set_creation_turn!(ctx.db, "wi_review_child", review_turn_seq)

    session_map =
      get(ctx, "/api/execution-map/tree", ctx.owner_session.cli_token)
      |> decode_success()

    roots = session_map["roots"]
    root_ids = Enum.map(roots, & &1["id"])
    assert Enum.sort(root_ids) == ["wi_child", "wi_review_child"]
    child = Enum.find(roots, &(&1["id"] == "wi_child"))
    assert child["parent"] == %{"status" => "from_turn", "item" => nil}
    review_child = Enum.find(roots, &(&1["id"] == "wi_review_child"))
    assert review_child["parent"] == %{"status" => "from_turn", "item" => nil}
    refute JSON.encode!(session_map) =~ "asg_hidden_middle"
    refute JSON.encode!(session_map) =~ "asg_visible_review"

    {owner_response, owner_events} = traced_get(ctx, "/api/execution-map", ctx.token)
    owner_map = decode_success(owner_response)

    assert Enum.map(owner_map["items"], & &1["id"]) == [
             "wi_parent",
             "wi_child",
             "wi_review_child"
           ]

    assert {:shared_lookup, "execution map", :query_execution_map} in owner_events
    assert {:au4_visibility, "work items"} in owner_events

    # The session grant exposes the work item only through the held assignment.
    holder_item =
      insert_work_item!(ctx.db, "wi_holder_only", "other", 30_000)

    insert_assignment!(ctx.db, "asg_holder_only",
      opener_user: "other",
      holder: ctx.owner_session.session_key,
      work_item_id: holder_item
    )

    assert_error(
      get(ctx, "/api/execution-map/assignments?assignmentId=asg_holder_only", ctx.token),
      404,
      "not_found"
    )

    holder_selection =
      get(
        ctx,
        "/api/execution-map/assignments?assignmentId=asg_holder_only&assignmentId=asg_holder_only",
        ctx.owner_session.cli_token
      )
      |> decode_success()

    assert Enum.map(holder_selection["items"], & &1["id"]) == ["wi_holder_only"]
    assert holder_selection["noItem"] == []

    user_map = get(ctx, "/api/execution-map", ctx.token) |> decode_success()
    assert Enum.map(user_map["items"], & &1["id"]) == ["wi_parent", "wi_child", "wi_review_child"]
    assert user_map["dependencyVersion"] =~ ~r/^[0-9a-f]{64}$/
    assert Enum.all?(user_map["items"], &(Enum.sort(Map.keys(&1)) == Enum.sort(@node_fields)))
    refute JSON.encode!(user_map) =~ "currentCoordination"
    refute JSON.encode!(user_map) =~ "createdAt"

    tree = get(ctx, "/api/execution-map/tree", ctx.token) |> decode_success()
    assert Enum.map(tree["roots"], & &1["id"]) == ["wi_parent", "wi_review_child"]
    assert Enum.map(hd(tree["roots"])["children"], & &1["id"]) == ["wi_child"]

    subtree = get(ctx, "/api/execution-map/subtrees/wi_parent", ctx.token) |> decode_success()
    assert Enum.map(subtree["roots"], & &1["id"]) == ["wi_parent"]
    assert Enum.map(hd(subtree["roots"])["children"], & &1["id"]) == ["wi_child"]

    for response <- [user_map, tree, subtree, holder_selection] do
      assert response["edgeBasis"] == "concurrent_turn"

      assert response["coverage"] == %{
               "attributionCutoff" => 1,
               "basis" => "conservative_shared"
             }

      assert response["dependencyVersion"] =~ ~r/^[0-9a-f]{64}$/
    end

    assert tree["dependencyVersion"] == user_map["dependencyVersion"]
    assert subtree["dependencyVersion"] == user_map["dependencyVersion"]

    selected =
      get(ctx, "/api/execution-map/assignments?assignmentId=asg_visible_review", ctx.token)

    assert_error(selected, 404, "not_found")

    assert_error(
      get(ctx, "/api/execution-map/tree?limit=1", ctx.token),
      400,
      "invalid_filter"
    )

    assert_error(
      get(
        ctx,
        "/api/execution-map/assignments?assignmentId=asg_visible_review&state=open",
        ctx.token
      ),
      400,
      "invalid_filter"
    )
  end

  test "roster filters are conjunctive and applied only to authorized items", ctx do
    spec_sha = String.duplicate("c", 64)

    visible =
      insert_work_item!(ctx.db, "wi_filter_visible", "owner", 10_000,
        created_by_session: ctx.owner_session.session_key,
        spec_ref_name: "map-spec",
        spec_ref_sha256: spec_sha
      )

    hidden =
      insert_work_item!(ctx.db, "wi_filter_hidden", "other", 11_000,
        created_by_session: ctx.owner_session.session_key,
        spec_ref_name: "map-spec",
        spec_ref_sha256: spec_sha
      )

    parent_assignment =
      insert_assignment!(ctx.db, "asg_filter_parent",
        opener_user: "owner",
        holder: ctx.owner_session.session_key,
        work_item_id: visible
      )

    {:ok, created_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: ctx.owner_session.session_key,
        message_id: "execution-map-filtered-child",
        origin: "user:owner",
        prompt: "execution map filtered child",
        assignment_id: parent_assignment
      })

    set_creation_turn!(ctx.db, hidden, created_seq)

    query =
      "origin=session&state=open&quietOverMs=0&specRefName=map-spec&specRefSha256=#{spec_sha}&sessionKey=#{ctx.owner_session.session_key}"

    response = get(ctx, "/api/execution-map?#{query}", ctx.token) |> decode_success()
    assert Enum.map(response["items"], & &1["id"]) == [visible]

    tree = get(ctx, "/api/execution-map/tree?#{query}", ctx.token) |> decode_success()
    assert Enum.map(tree["roots"], & &1["id"]) == [visible]
    refute JSON.encode!(tree) =~ hidden

    subtree =
      get(ctx, "/api/execution-map/subtrees/#{visible}?#{query}", ctx.token) |> decode_success()

    assert Enum.map(subtree["roots"], & &1["id"]) == [visible]
    refute JSON.encode!(subtree) =~ hidden
    assert tree["dependencyVersion"] == response["dependencyVersion"]
    assert subtree["dependencyVersion"] == response["dependencyVersion"]

    assert get(ctx, "/api/execution-map?#{query}&ownerUserId=missing", ctx.token)
           |> decode_success()
           |> Map.fetch!("items") == []

    for suffix <- [
          "origin=process",
          "state=ready",
          "ownerUserId=",
          "sessionKey=",
          "specRefName=",
          "specRefSha256=#{String.duplicate("C", 64)}&specRefName=map-spec",
          "specRefSha256=#{spec_sha}&specRefName=",
          "quietOverMs=1.5",
          "quietOverMs=+1",
          "quietOverMs=01",
          "quietOverMs=",
          "state=open&state=closed"
        ] do
      assert_error(get(ctx, "/api/execution-map?#{suffix}", ctx.token), 400, "invalid_filter")
    end
  end

  test "assignment selection returns no-item ids, collapses duplicates, and reports visible ambiguity",
       ctx do
    item = insert_work_item!(ctx.db, "wi_selected", "owner", 10_000)

    insert_assignment!(ctx.db, "asg_select_one",
      opener_user: "owner",
      holder: ctx.owner_session.session_key,
      work_item_id: item
    )

    insert_assignment!(ctx.db, "asg_select_none",
      opener_user: "owner",
      holder: ctx.owner_session.session_key
    )

    insert_assignment!(ctx.db, "asg_shared_alpha",
      opener_user: "owner",
      holder: ctx.owner_session.session_key
    )

    insert_assignment!(ctx.db, "asg_shared_beta",
      opener_user: "owner",
      holder: ctx.owner_session.session_key
    )

    response =
      get(
        ctx,
        "/api/execution-map/assignments?assignmentId=asg_select_one&assignmentId=asg_select_one&assignmentId=asg_select_none",
        ctx.token
      )
      |> decode_success()

    assert Enum.map(response["items"], & &1["id"]) == ["wi_selected"]
    assert response["noItem"] == ["asg_select_none"]

    ambiguous = get(ctx, "/api/execution-map/assignments?assignmentId=asg_shared_", ctx.token)
    assert ambiguous.status == 400

    assert JSON.decode!(ambiguous.resp_body)["error"] == %{
             "code" => "ambiguous_id",
             "candidateIds" => ["asg_shared_alpha", "asg_shared_beta"]
           }

    assert_error(get(ctx, "/api/execution-map/assignments", ctx.token), 400, "invalid_filter")

    assert_error(
      get(ctx, "/api/execution-map/assignments?assignmentId=asg_absent", ctx.token),
      404,
      "not_found"
    )
  end

  test "flat keysets keep tuple order, cap pages, and bind decoded filters in fixed order", ctx do
    ids = insert_page_items!(ctx.db, "wi_page_", 503, 50_000)

    default_page = get(ctx, "/api/execution-map", ctx.token) |> decode_success()
    assert Enum.map(default_page["items"], & &1["id"]) == Enum.take(ids, -50)
    assert default_page["page"]["hasMoreBefore"]

    capped = get(ctx, "/api/execution-map?limit=501", ctx.token) |> decode_success()
    assert length(capped["items"]) == 500
    assert Enum.map(capped["items"], & &1["id"]) == Enum.take(ids, -500)
    assert capped["page"]["hasMoreBefore"]

    cursor = capped["page"]["oldestCursor"]
    decoded_cursor = cursor |> Base.url_decode64!(padding: false) |> JSON.decode!()
    assert decoded_cursor["tuple"] == [50_000, Enum.at(ids, 3)]
    refute Map.has_key?(decoded_cursor, "offset")
    refute Map.has_key?(decoded_cursor, "rowid")
    refute Map.has_key?(decoded_cursor, "locator")

    assert {:ok, _rows} =
             DB.query(ctx.db, "DELETE FROM work_items WHERE id IN (?1, ?2, ?3)", [
               Enum.at(ids, 2),
               Enum.at(ids, 3),
               Enum.at(ids, 4)
             ])

    prior =
      get(ctx, "/api/execution-map?before=" <> URI.encode_www_form(cursor), ctx.token)
      |> decode_success()

    assert Enum.map(prior["items"], & &1["id"]) == Enum.take(ids, 2)
    assert prior["page"]["hasMoreAfter"]

    filtered =
      get(ctx, "/api/execution-map?state=open&limit=1", ctx.token)
      |> decode_success()

    [filtered_cursor] = [filtered["page"]["newestCursor"]]

    fingerprint =
      [nil, nil, "open", nil, nil, nil, nil]
      |> JSON.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    payload = filtered_cursor |> Base.url_decode64!(padding: false) |> JSON.decode!()
    assert payload["filters"] == fingerprint

    changed_filter =
      get(
        ctx,
        "/api/execution-map?state=closed&after=" <> URI.encode_www_form(filtered_cursor),
        ctx.token
      )

    assert_error(changed_filter, 400, "invalid_cursor")

    wrong_principal =
      get(
        ctx,
        "/api/execution-map?state=open&after=" <> URI.encode_www_form(filtered_cursor),
        ctx.owner_session.cli_token
      )

    assert_error(wrong_principal, 404, "not_found")

    malformed_tuple =
      payload
      |> Map.put("tuple", [50_000])
      |> JSON.encode!()
      |> Base.url_encode64(padding: false)

    assert_error(
      get(
        ctx,
        "/api/execution-map?state=open&after=" <> URI.encode_www_form(malformed_tuple),
        ctx.token
      ),
      400,
      "invalid_cursor"
    )

    assert_error(
      get(
        ctx,
        "/api/work-items?after=" <> URI.encode_www_form(filtered_cursor),
        ctx.token
      ),
      400,
      "work items",
      "invalid_cursor"
    )

    for suffix <- [
          "tail=false",
          "origin=user&origin=session",
          "quietOverMs=-1",
          "specRefSha256=#{String.duplicate("a", 64)}",
          "unknown=x",
          "limit=0"
        ] do
      assert_error(get(ctx, "/api/execution-map?#{suffix}", ctx.token), 400, "invalid_filter")
    end
  end

  test "a cursor whose boundary becomes hidden continues over the authorized tuple set", ctx do
    ids = insert_page_items!(ctx.db, "wi_hidden_page_", 3, 60_000)

    latest = get(ctx, "/api/execution-map?limit=1", ctx.token) |> decode_success()
    boundary = latest["page"]["oldestCursor"]

    previous =
      get(ctx, "/api/execution-map?before=" <> URI.encode_www_form(boundary), ctx.token)
      |> decode_success()

    hidden_item = hd(previous["items"])["id"]
    hidden_cursor = previous["page"]["newestCursor"]

    assert {:ok, _rows} =
             DB.query(ctx.db, "UPDATE work_items SET ownerUserId='other' WHERE id=?1", [
               hidden_item
             ])

    next =
      get(ctx, "/api/execution-map?after=" <> URI.encode_www_form(hidden_cursor), ctx.token)
      |> decode_success()

    assert Enum.map(next["items"], & &1["id"]) == [List.last(ids)]
    refute Enum.any?(next["items"], &(&1["id"] == hidden_item))
  end

  test "the router delegates projection and keeps generic cursor seams as the fallback" do
    router = File.read!("lib/tightbeam/wire/router.ex")
    execution_map = File.read!("lib/tightbeam/execution_map.ex")
    visibility = File.read!("lib/tightbeam/state_visibility.ex")

    assert router =~ "Tightbeam.ExecutionMap.list_execution_map"
    assert router =~ "Tightbeam.ExecutionMap.query_execution_map_tree"
    assert router =~ "Tightbeam.ExecutionMap.query_execution_map_subtree"
    assert router =~ "Tightbeam.ExecutionMap.query_execution_map_assignments"
    assert router =~ "Tightbeam.ExecutionMap.execution_map_node/1"
    assert router =~ "d1_filter_fingerprint(filters)"
    assert router =~ "d1_cursor_filter_fingerprint(spec, filters)"
    assert execution_map =~ "def execution_map_node(node)"
    assert visibility =~ "def execution_map_node_visible?"
    assert visibility =~ "query_work_item(source, work_item_id"
    assert execution_map =~ "StateVisibility.execution_map_node_visible?"
    refute router =~ "defp execution_map_node"
    refute router =~ "defp execution_map_node_fields"
    refute router =~ "defp d2_cursor"
  end

  defp approved_device(db, device_id, name, user_id) do
    {:pending, _device} =
      Devices.pair(db, %{device_id: device_id, claimed_name: name, platform: nil, model: nil})

    Devices.approve(db, device_id, user_id)
  end

  defp insert_work_item!(db, id, owner, created_at, opts \\ []) do
    created_by_session = Keyword.get(opts, :created_by_session)
    created_by_user = if is_nil(created_by_session), do: owner, else: nil

    assert {:ok, _rows} =
             DB.query(
               db,
               """
               INSERT INTO work_items
                 (id, title, specRefName, specRefSha256, isBug, ownerUserId, state, createdByUser, createdBySession,
                  createdInTurnSeq, createdContextKnown, createdAt)
               VALUES (?1, ?2, ?3, ?4, 0, ?5, 'open', ?6, ?7, NULL, 0, ?8)
               """,
               [
                 id,
                 "Item #{id}",
                 Keyword.get(opts, :spec_ref_name),
                 Keyword.get(opts, :spec_ref_sha256),
                 owner,
                 created_by_user,
                 created_by_session,
                 created_at
               ]
             )

    id
  end

  defp set_creation_turn!(db, work_item_id, turn_seq) do
    assert {:ok, _rows} =
             DB.query(
               db,
               "UPDATE work_items SET createdInTurnSeq=?2, createdContextKnown=1 WHERE id=?1",
               [work_item_id, turn_seq]
             )
  end

  defp insert_assignment!(db, id, opts) do
    assert {:ok, _rows} =
             DB.query(
               db,
               """
               INSERT INTO assignments
                 (id, subject, holderKey, openedByUser, openedAt, state, workItemId,
                  reviewsAssignmentId)
               VALUES (?1, ?2, ?3, ?4, 1, 'open', ?5, ?6)
               """,
               [
                 id,
                 "Assignment #{id}",
                 Keyword.fetch!(opts, :holder),
                 Keyword.fetch!(opts, :opener_user),
                 Keyword.get(opts, :work_item_id),
                 Keyword.get(opts, :reviews)
               ]
             )

    id
  end

  defp insert_page_items!(db, prefix, count, created_at) do
    ids = Enum.map(0..(count - 1), &(prefix <> String.pad_leading(Integer.to_string(&1), 4, "0")))

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Enum.each(ids, fn id ->
                 Tightbeam.DB.Txn.q(
                   txn,
                   """
                   INSERT INTO work_items
                     (id, title, isBug, ownerUserId, state, createdByUser, createdContextKnown, createdAt)
                   VALUES (?1, ?2, 0, 'owner', 'open', 'owner', 0, ?3)
                   """,
                   [id, "Item #{id}", created_at]
                 )
               end)

               :ok
             end)

    ids
  end

  defp get(ctx, path, bearer \\ nil) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{bearer || ctx.token}")
    |> Router.call(Router.init(ctx.opts))
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

  defp decode_success(response) do
    assert response.status == 200, response.resp_body
    JSON.decode!(response.resp_body)
  end

  defp assert_error(response, status, code) do
    assert_error(response, status, "execution map", code)
  end

  defp assert_error(response, status, resource, code) do
    assert response.status == status

    assert response.resp_body ==
             ~s({"schemaVersion":1,"resource":"#{resource}","error":{"code":"#{code}"}})
  end
end
