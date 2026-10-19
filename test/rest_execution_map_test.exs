defmodule Tightbeam.RestExecutionMapTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{
    Archetypes,
    DB,
    Devices,
    ExecutionMap,
    Identity,
    Ledger,
    LiveBaseAdmission,
    LiveBaseGuard,
    LiveBasePayload,
    Schema
  }
  alias Tightbeam.Firehose.Hub
  alias Tightbeam.Wire.Router

  @node_fields ~w(
    id title specRefName specRefSha256 state failReason bracket1Armed origin
    creationContext parent finishedAt assignments jobs attests startedAt
    closingAttests openDecisionRequests turns minds fanOut active sinceProgressMs
  )
  @envelope_fields ~w(schemaVersion resource edgeBasis coverage dependencyVersion)

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

  test "empty and populated modes use canonical no-store response envelopes", ctx do
    empty_flat = get(ctx, "/api/execution-map", ctx.token)
    flat = assert_execution_map_response(empty_flat, ~w(items page))
    assert flat["items"] == []

    assert flat["page"] == %{
             "oldestCursor" => nil,
             "newestCursor" => nil,
             "hasMoreBefore" => false,
             "hasMoreAfter" => false
           }

    assert flat["edgeBasis"] == "concurrent_turn"
    assert flat["coverage"] == %{"attributionCutoff" => 1, "basis" => "conservative_shared"}
    assert flat["dependencyVersion"] =~ ~r/^[0-9a-f]{64}$/

    empty_tree = get(ctx, "/api/execution-map/tree", ctx.token)
    assert assert_execution_map_response(empty_tree, ~w(roots))["roots"] == []

    item = insert_work_item!(ctx.db, "wi_envelope", "owner", 40_000)

    assignment =
      insert_assignment!(ctx.db, "asg_envelope_no_item",
        opener_user: "owner",
        holder: ctx.owner_session.session_key
      )

    for {path, shape, field, expected, no_item_ids} <- [
          {"/api/execution-map", ~w(items page), "items", [item], nil},
          {"/api/execution-map/tree", ~w(roots), "roots", [item], nil},
          {"/api/execution-map/subtrees/#{item}", ~w(roots), "roots", [item], nil},
          {
            "/api/execution-map/assignments?assignmentId=#{assignment}",
            ~w(items noItem),
            "items",
            [],
            [assignment]
          }
        ] do
      decoded = get(ctx, path, ctx.token) |> assert_execution_map_response(shape)
      assert Enum.map(decoded[field], & &1["id"]) == expected
      assert decoded["edgeBasis"] == "concurrent_turn"
      if no_item_ids, do: assert(decoded["noItem"] == no_item_ids)
    end

    linked_assignment =
      insert_assignment!(ctx.db, "asg_envelope_linked",
        opener_user: "owner",
        holder: ctx.owner_session.session_key,
        work_item_id: item
      )

    linked_selection =
      get(ctx, "/api/execution-map/assignments?assignmentId=#{linked_assignment}", ctx.token)
      |> assert_execution_map_response(~w(items noItem))

    assert Enum.map(linked_selection["items"], & &1["id"]) == [item]
    assert linked_selection["noItem"] == []
  end

  test "file-backed read snapshots do not hold the single writer", _ctx do
    base_dir =
      System.tmp_dir!()
      |> Path.join("tightbeam-execution-map-read-snapshot-#{System.unique_integer([:positive])}")
      |> LiveBaseAdmission.canonical!()

    File.mkdir_p!(base_dir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    payload_root = Path.join(base_dir, "payload")
    File.mkdir_p!(Path.join(payload_root, "ebin"))
    File.mkdir_p!(Path.join(payload_root, "priv"))
    File.write!(Path.join(payload_root, "priv/read-snapshot-test"), "test payload")
    {:ok, manifest} = LiveBaseGuard.generate_manifest(LiveBasePayload.files!(payload_root))
    File.write!(Path.join(payload_root, "build-manifest.json"), JSON.encode!(manifest))

    db =
      start_supervised!(
        Supervisor.child_spec(
          {DB,
           path: Path.join(base_dir, "state.db"),
           name: nil,
           guard_inputs: [],
           payload_root: payload_root},
          id: {:execution_map_read_snapshot, System.unique_integer([:positive])}
        )
      )

    :ok = DB.execute(db, "CREATE TABLE read_snapshot_probe (value INTEGER NOT NULL)")
    :ok = DB.execute(db, "INSERT INTO read_snapshot_probe (value) VALUES (1)")

    parent = self()

    reader_task =
      Task.async(fn ->
        DB.read_transaction(db, fn txn ->
          before = Tightbeam.DB.Txn.q(txn, "SELECT value FROM read_snapshot_probe")
          send(parent, {:read_snapshot_started, before, self()})

          receive do
            :continue -> :ok
          after
            10_000 -> raise "read snapshot was not released"
          end

          after_write = Tightbeam.DB.Txn.q(txn, "SELECT value FROM read_snapshot_probe")
          {before, after_write}
        end)
      end)

    assert_receive {:read_snapshot_started, [[1]], reader_conn}, 5_000

    writer =
      Task.async(fn ->
        DB.transaction(db, fn txn ->
          Tightbeam.DB.Txn.q(txn, "UPDATE read_snapshot_probe SET value = 2")
          :written
        end)
      end)

    write_result = Task.yield(writer, 2_000)
    send(reader_conn, :continue)

    assert {:ok, {:ok, :written}} = write_result
    assert {:ok, {[[1]], [[1]]}} = Task.await(reader_task, 5_000)
    assert {:ok, [[2]]} = DB.query(db, "SELECT value FROM read_snapshot_probe")
  end

  test "the public node serializer fixes wire bytes across 1,000 shuffled maps and sets" do
    node = serializer_node_fixture()

    expected =
      [
        ~s({"id":"wi_serializer","title":"Stable node"),
        ~s(,"specRefName":null,"specRefSha256":null),
        ~s(,"state":"open","failReason":null,"bracket1Armed":false),
        ~s(,"origin":{"principal":"user","createdBy":"owner"}),
        ~s(,"creationContext":{"recorded":true,"turnSeq":7}),
        ~s(,"parent":{"status":"from_turn","item":null},"finishedAt":null),
        ~s(,"assignments":{"open":2,"closed":1),
        ~s(,"byOutcome":{"completed":1,"surrendered":0,"revoked":0}}),
        ~s(,"jobs":2),
        ~s(,"attests":{"total":2,"byKind":{"completion":1,"progress":1},),
        ~s("byVerdictKind":{"landed":1}}),
        ~s(,"startedAt":15),
        ~s(,"closingAttests":[{"assignmentId":"asg_a","attestId":"att_a",),
        ~s("commitRefs":[{"repo":"repo-a","commit":"abc"}]},),
        ~s({"assignmentId":"asg_z","attestId":"att_z","commitRefs":null}]),
        ~s(,"openDecisionRequests":1,"turns":{"total":3,"lastEndedAt":25}),
        ~s(,"minds":[{"model":"claude","context":null,"effort":"high","harness":"claude"},),
        ~s({"model":"gpt","context":"long","effort":"max","harness":"codex"}]),
        ~s(,"fanOut":null),
        ~s(,"active":{"runningTurn":false,"pendingSessionWake":true,),
        ~s("pendingWakeClasses":{"fyi":2,"input-needed":1}}),
        ~s(,"sinceProgressMs":10})
      ]
      |> Enum.join()

    assert ExecutionMap.execution_map_node(node) == expected

    child = Map.put(node, :id, "wi_child")
    tree_node = Map.put(node, :children, [child])

    expected_child = String.replace(expected, "wi_serializer", "wi_child", global: false)
    expected_parent = binary_part(expected, 0, byte_size(expected) - 1)
    expected_tree = expected_parent <> ",\"children\":[" <> expected_child <> "]}"

    assert ExecutionMap.execution_map_node(tree_node) == expected_tree

    for seed <- 1..1_000 do
      shuffled = shuffle_execution_map_sets(shuffle_map_order(node, seed), seed)
      shuffled_child = shuffle_execution_map_sets(shuffle_map_order(child, seed), seed)
      shuffled_tree =
        Map.put(shuffle_execution_map_sets(shuffle_map_order(node, seed), seed), :children, [
          shuffled_child
        ])

      assert ExecutionMap.execution_map_node(shuffled) == expected
      assert ExecutionMap.execution_map_node(shuffled_tree) == expected_tree
    end
  end

  test "hidden-only state is byte-identical to its absence in the composed response", ctx do
    before = get(ctx, "/api/execution-map", ctx.token)
    assert decode_success(before)["items"] == []
    assert get_resp_header(before, "cache-control") == ["no-store"]
    assert {:ok, [[cutoff]]} = DB.query(ctx.db, "SELECT at FROM causal_events_epoch WHERE id=0")

    hidden_item = insert_work_item!(ctx.db, "wi_hidden_twin", "other", 41_000)

    hidden_assignment =
      insert_assignment!(ctx.db, "asg_hidden_twin",
        opener_user: "other",
        holder: ctx.other_session.session_key,
        work_item_id: hidden_item
      )

    assert {:ok, _rows} =
             DB.query(
               ctx.db,
               """
               INSERT INTO attests (id, assignmentId, kind, bySession, ts)
               VALUES (?1, ?2, 'progress', ?3, ?4)
               """,
               ["att_hidden_twin", hidden_assignment, ctx.other_session.session_key, 1]
             )

    assert {:ok, _seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: ctx.other_session.session_key,
               message_id: "execution-map-hidden-twin-turn",
               origin: "user:other",
               prompt: "hidden turn data",
               job_ref: hidden_item
             })

    assert {:ok, _rows} =
             DB.query(ctx.db, "UPDATE causal_events_epoch SET at=?1 WHERE id=0", [cutoff])

    after_hidden = get(ctx, "/api/execution-map", ctx.token)
    assert get_resp_header(after_hidden, "cache-control") == ["no-store"]
    assert response_signature(after_hidden) == response_signature(before)
  end

  test "dependency versions change for visible sources and ignore hidden or unlisted changes",
       ctx do
    visible = insert_work_item!(ctx.db, "wi_dependency_visible", "owner", 42_000)
    hidden = insert_work_item!(ctx.db, "wi_dependency_hidden", "other", 43_000)

    baseline = get(ctx, "/api/execution-map", ctx.token) |> decode_success()
    assert Enum.map(baseline["items"], & &1["id"]) == [visible]
    baseline_version = baseline["dependencyVersion"]

    assert {:ok, _rows} =
             DB.query(
               ctx.db,
               "UPDATE work_items SET title='Visible changed' WHERE id=?1",
               [visible]
             )

    stamp_work_item_version!(ctx.db, visible, 42_001)

    visible_changed = get(ctx, "/api/execution-map", ctx.token) |> decode_success()
    refute visible_changed["dependencyVersion"] == baseline_version

    assert {:ok, _rows} =
             DB.query(
               ctx.db,
               "UPDATE work_items SET title='Hidden changed' WHERE id=?1",
               [hidden]
             )

    stamp_work_item_version!(ctx.db, hidden, 43_001)

    hidden_changed = get(ctx, "/api/execution-map", ctx.token) |> decode_success()
    assert hidden_changed["dependencyVersion"] == visible_changed["dependencyVersion"]

    assert {:ok, _rows} =
             DB.query(
               ctx.db,
               "UPDATE devices SET claimedName='Renamed device' WHERE deviceId=?1",
               ["execution-map-owner-device"]
             )

    unlisted_changed = get(ctx, "/api/execution-map", ctx.token) |> decode_success()
    assert unlisted_changed["dependencyVersion"] == hidden_changed["dependencyVersion"]
  end

  test "all unpaged routes reject each page parameter before the resource query", ctx do
    item = insert_work_item!(ctx.db, "wi_unpaged", "owner", 44_000)

    assignment =
      insert_assignment!(ctx.db, "asg_unpaged",
        opener_user: "owner",
        holder: ctx.owner_session.session_key,
        work_item_id: item
      )

    routes = [
      "/api/execution-map/tree",
      "/api/execution-map/subtrees/#{item}",
      "/api/execution-map/assignments?assignmentId=#{assignment}"
    ]

    for route <- routes, parameter <- ["before=opaque", "after=opaque", "limit=1"] do
      separator = if String.contains?(route, "?"), do: "&", else: "?"
      {response, events} = traced_get(ctx, route <> separator <> parameter, ctx.token)
      assert_error(response, 400, "invalid_filter")
      refute Enum.any?(events, &match?({:shared_lookup, "execution map", _}, &1))
    end
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

  defp serializer_node_fixture do
    %{
      id: "wi_serializer",
      title: "Stable node",
      spec_ref_name: nil,
      spec_ref_sha256: nil,
      state: "open",
      fail_reason: nil,
      bracket1_armed: false,
      origin: %{principal: "user", created_by: "owner"},
      creation_context: %{recorded: true, turn_seq: 7},
      parent: %{status: "from_turn", item: nil},
      finished_at: nil,
      assignments: %{
        open: 2,
        closed: 1,
        by_outcome: %{completed: 1, surrendered: 0, revoked: 0}
      },
      jobs: 2,
      attests: %{
        total: 2,
        by_kind: %{"progress" => 1, "completion" => 1},
        by_verdict_kind: %{"landed" => 1}
      },
      started_at: 15,
      closing_attests: [
        %{
          assignmentId: "asg_a",
          attestId: "att_a",
          commitRefs: [%{"repo" => "repo-a", "commit" => "abc"}]
        },
        %{assignmentId: "asg_z", attestId: "att_z", commitRefs: nil}
      ],
      open_decision_requests: 1,
      turns: %{total: 3, last_ended_at: 25},
      minds: [
        %{model: "claude", context: nil, effort: "high", harness: "claude"},
        %{model: "gpt", context: "long", effort: "max", harness: "codex"}
      ],
      fan_out: nil,
      active: %{
        running_turn: false,
        pending_session_wake: true,
        pending_wake_classes: %{"fyi" => 2, "input-needed" => 1}
      },
      since_progress_ms: 10
    }
  end

  defp shuffle_map_order(value, seed) when is_map(value) do
    value
    |> Enum.map(fn {key, child} -> {key, shuffle_map_order(child, :erlang.phash2({seed, key}))} end)
    |> Enum.sort_by(fn {key, _child} -> {:erlang.phash2({seed, key}), key} end)
    |> Map.new()
  end

  defp shuffle_map_order(value, seed) when is_list(value),
    do: Enum.map(value, &shuffle_map_order(&1, seed))

  defp shuffle_map_order(value, _seed), do: value

  defp shuffle_execution_map_sets(node, seed) do
    node
    |> Map.update!(:closing_attests, &shuffle_set_order(&1, seed))
    |> Map.update!(:minds, &shuffle_set_order(&1, seed + 1_000))
  end

  defp shuffle_set_order(values, seed) do
    Enum.sort_by(values, &{:erlang.phash2({seed, &1}), :erlang.term_to_binary(&1)})
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

  defp stamp_work_item_version!(db, work_item_id, row_version) do
    assert {:ok, _rows} =
             DB.query(
               db,
               "INSERT INTO work_item_versions (workItemId, rowVersion) VALUES (?1, ?2)",
               [work_item_id, row_version]
             )
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

  defp assert_execution_map_response(response, mode_fields) do
    decoded = decode_success(response)
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert decoded["schemaVersion"] == 1
    assert decoded["resource"] == "execution map"
    assert decoded["edgeBasis"] == "concurrent_turn"
    assert Enum.sort(Map.keys(decoded["coverage"])) == ~w(attributionCutoff basis)
    assert is_integer(decoded["coverage"]["attributionCutoff"])
    assert decoded["coverage"]["attributionCutoff"] > 0
    assert decoded["coverage"]["basis"] == "conservative_shared"
    assert decoded["dependencyVersion"] =~ ~r/^[0-9a-f]{64}$/

    assert Enum.sort(Map.keys(decoded)) ==
             Enum.sort(@envelope_fields ++ mode_fields)

    decoded
  end

  defp response_signature(response) do
    {
      response.status,
      get_resp_header(response, "content-type"),
      get_resp_header(response, "cache-control"),
      response.resp_body
    }
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
