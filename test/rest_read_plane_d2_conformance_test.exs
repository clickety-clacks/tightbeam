defmodule Tightbeam.RestReadPlaneD2ConformanceTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{
    CausalEvents,
    DB,
    Devices,
    ExecutionMap,
    Identity,
    Org,
    Schema,
    StateResources,
    Wakes
  }

  alias Tightbeam.DB.Txn
  alias Tightbeam.Wire.Router

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-rest-d2-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    :initialized = Identity.init!(base_dir)
    Tightbeam.Archetypes.load!(base_dir)

    db = :"rest_d2_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)

    {:paired, admin_device} =
      claim_org(db, %{
        device_id: "d2-admin",
        claimed_name: "sample-user",
        platform: nil,
        model: nil
      })

    admin_session = ensure_main_session(db, admin_device.user_id)
    Devices.add_user(db, "observer", false)
    observer_session = ensure_main_session(db, "observer")

    opts = [
      db: db,
      base_dir: base_dir,
      handlers: %{},
      cli_token: "tbc_rest_d2",
      model_catalog: %{},
      session_status: fn _ -> nil end
    ]

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{
      db: db,
      base_dir: base_dir,
      opts: opts,
      admin_device: admin_device,
      admin_session: admin_session,
      observer_session: observer_session
    }
  end

  test "coordination share uses the half-open window, visible session, and ordered R7 item",
       ctx do
    from = 1_000
    to = 1_100
    session_key = ctx.admin_session.session_key

    fyi = schedule_wake(ctx.db, session_key, "w_d2d_fyi", "fyi prompt", from)

    algedonic =
      schedule_wake(ctx.db, session_key, "w_d2d_alarm", "alarm prompt", from, "algedonic")

    upper_bound_wake =
      schedule_wake(ctx.db, session_key, "w_d2d_upper", "upper bound", to)

    turn(ctx.db, session_key, nil, from)
    turn(ctx.db, session_key, fyi.wake_id, from + 50)
    turn(ctx.db, session_key, algedonic.wake_id, from + 75)
    turn(ctx.db, session_key, upper_bound_wake.wake_id, to)

    response =
      get(
        ctx,
        "/api/sessions/#{session_key}/coordination-share?from=#{from}&to=#{to}",
        ctx.admin_device.token
      )

    assert response.status == 200, response.resp_body
    assert get_resp_header(response, "cache-control") == ["no-store"]

    envelope = JSON.decode!(response.resp_body)
    item = envelope["item"]

    assert envelope["resource"] == "coordination share"
    assert Map.keys(envelope) |> Enum.sort() == ~w(item resource schemaVersion)

    assert Map.keys(item) |> Enum.sort() ==
             ~w(algedonic byClass classedTurns coordinationTurns dependencyVersion from sessionKey share summons to turns wakeTurns)

    assert item["sessionKey"] == session_key
    assert item["from"] == from
    assert item["to"] == to
    assert item["turns"] == 3
    assert item["wakeTurns"] == 2
    assert item["classedTurns"] == 2
    assert item["coordinationTurns"] == 1
    assert item["summons"] == 0
    assert item["algedonic"] == 1
    assert item["byClass"] == %{"algedonic" => 1, "fyi" => 1}
    assert item["share"] == 1 / 3
    assert item["dependencyVersion"] =~ ~r/\A[0-9a-f]{64}\z/

    assert item["dependencyVersion"] ==
             coordination_dependency_version(ctx.db, session_key, from, to)

    query =
      ExecutionMap.query_coordination_share(ctx.db, %{
        key: session_key,
        from: from,
        to: to,
        principal: user_principal(ctx.admin_device)
      })

    expected = StateResources.coordination_share(query)
    expected_bytes = StateResources.encode_item("coordination share", expected, %{})
    assert response.resp_body =~ ~s("item":#{expected_bytes})

    first_version = item["dependencyVersion"]

    {:ok, _event_seq} =
      DB.transaction(ctx.db, fn txn ->
        :ok =
          CausalEvents.append_in_txn(txn, %{
            kind: "prod_fired",
            session_key: session_key,
            at: from + 90,
            detail: %{tier: 1}
          })

        [[seq]] = Txn.q(txn, "SELECT last_insert_rowid()")
        seq
      end)

    updated =
      get(
        ctx,
        "/api/sessions/#{session_key}/coordination-share?from=#{from}&to=#{to}",
        ctx.admin_device.token
      )

    updated_item = JSON.decode!(updated.resp_body)["item"]

    assert updated_item["dependencyVersion"] ==
             coordination_dependency_version(ctx.db, session_key, from, to)

    refute updated_item["dependencyVersion"] == first_version
    assert Map.drop(updated_item, ["dependencyVersion"]) == Map.drop(item, ["dependencyVersion"])

    for path <- [
          "/api/sessions/#{session_key}/coordination-share?to=#{to}",
          "/api/sessions/#{session_key}/coordination-share?from=#{from}&from=#{from}&to=#{to}",
          "/api/sessions/#{session_key}/coordination-share?from=#{to}&to=#{from}",
          "/api/sessions/#{session_key}/coordination-share?from=#{from}&to=#{to}&limit=1",
          "/api/sessions/#{session_key}/coordination-share?from=#{from}&to=#{to}&extra=x"
        ] do
      invalid = get(ctx, path, ctx.admin_device.token)
      assert invalid.status == 400, path
      assert JSON.decode!(invalid.resp_body)["error"]["code"] == "invalid_filter", path
    end

    forbidden =
      get(
        ctx,
        "/api/sessions/#{session_key}/coordination-share?from=#{from}&to=#{to}",
        ctx.observer_session.cli_token
      )

    unknown =
      get(
        ctx,
        "/api/sessions/unknown-session-key/coordination-share?from=#{from}&to=#{to}",
        ctx.observer_session.cli_token
      )

    assert forbidden.status == 404
    assert forbidden.resp_body == unknown.resp_body
  end

  test "coordination share dependency query supports more wakes than SQLite bind parameters",
       ctx do
    wake_count = 32_767
    session_key = ctx.admin_session.session_key
    from = 1_000
    to = 1_100
    created_at = from + 50

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        WITH RECURSIVE n(value) AS (
          SELECT 1
          UNION ALL
          SELECT value + 1 FROM n WHERE value < ?3
        )
        INSERT INTO wakes (wakeId, sessionKey, origin, prompt, dueAt, createdAt)
        SELECT 'w_d2d_large_' || value, ?1, 'user:fixture', 'large window', ?2, ?2
        FROM n
        """,
        [session_key, created_at, wake_count]
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        WITH RECURSIVE n(value) AS (
          SELECT 1
          UNION ALL
          SELECT value + 1 FROM n WHERE value < ?3
        )
        INSERT INTO turns (sessionKey, messageId, wakeId, origin, prompt, status, createdAt)
        SELECT ?1, 'm_d2d_large_' || value, 'w_d2d_large_' || value,
               'user:fixture', 'large window', 'delivered', ?2
        FROM n
        """,
        [session_key, created_at, wake_count]
      )

    response =
      get(
        ctx,
        "/api/sessions/#{session_key}/coordination-share?from=#{from}&to=#{to}",
        ctx.admin_device.token
      )

    assert response.status == 200, response.resp_body

    item = JSON.decode!(response.resp_body)["item"]
    assert item["turns"] == wake_count
    assert item["wakeTurns"] == wake_count
    assert item["dependencyVersion"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "digest members retain carrier membership, canonical order, closed fields, and parent visibility",
       ctx do
    session_key = ctx.admin_session.session_key

    first = schedule_wake(ctx.db, session_key, "w_z_d2d_first", "first member", 0)
    second = schedule_wake(ctx.db, session_key, "w_a_d2d_second", "second member", 0)
    materialize_at = max(first.due_at, second.due_at)
    assert [carrier_id] = Wakes.materialize_digests(ctx.db, materialize_at)

    # Make the canonical tuple order differ from the batch's filing order so
    # this test catches reuse of publicationSeq as the REST ordering rule.
    {:ok, _} =
      DB.query(ctx.db, "UPDATE wakes SET createdAt=30000 WHERE wakeId=?1", [first.wake_id])

    {:ok, _} =
      DB.query(ctx.db, "UPDATE wakes SET createdAt=20000 WHERE wakeId=?1", [second.wake_id])

    legacy_order = Wakes.digest_members(ctx.db, carrier_id) |> Enum.map(& &1.wake_id)
    assert legacy_order == [first.wake_id, second.wake_id]

    response = get(ctx, "/api/wakes/#{carrier_id}/digest-members", ctx.admin_device.token)
    assert response.status == 200, response.resp_body
    assert get_resp_header(response, "cache-control") == ["no-store"]

    envelope = JSON.decode!(response.resp_body)
    assert envelope["resource"] == "digest members"
    assert Map.keys(envelope) |> Enum.sort() == ~w(items resource schemaVersion)
    assert Enum.map(envelope["items"], & &1["wakeId"]) == [second.wake_id, first.wake_id]

    assert Enum.all?(
             envelope["items"],
             &(Map.keys(&1) |> Enum.sort() ==
                 ~w(class classElection createdAt dependencyVersion prompt wakeId))
           )

    assert Enum.all?(
             envelope["items"],
             &(is_binary(&1["dependencyVersion"]) and byte_size(&1["dependencyVersion"]) == 64)
           )

    refute Map.has_key?(envelope, "page")

    expected_version =
      digest_dependency_version(ctx.db, [carrier_id, first.wake_id, second.wake_id])

    assert Enum.all?(envelope["items"], &(&1["dependencyVersion"] == expected_version))

    rows =
      Wakes.query_digest_members(ctx.db, %{
        key: carrier_id,
        principal: user_principal(ctx.admin_device)
      })

    expected = Enum.map(rows, &StateResources.digest_member/1)

    expected_bytes =
      Enum.map_join(expected, ",", &StateResources.encode_item("digest members", &1, %{}))

    assert response.resp_body ==
             ~s({"schemaVersion":1,"resource":"digest members","items":[#{expected_bytes}]})

    normal_wake =
      Wakes.schedule(ctx.db, %{
        session_key: session_key,
        origin: "user:fixture",
        prompt: "ordinary",
        due_at: 10_000,
        creator_session_key: session_key
      })

    unknown = get(ctx, "/api/wakes/w_d2d_missing/digest-members", ctx.admin_device.token)

    non_carrier =
      get(ctx, "/api/wakes/#{normal_wake.wake_id}/digest-members", ctx.admin_device.token)

    forbidden =
      get(ctx, "/api/wakes/#{carrier_id}/digest-members", ctx.observer_session.cli_token)

    assert unknown.status == 404
    assert non_carrier.status == 404
    assert forbidden.status == 404
    assert unknown.resp_body == non_carrier.resp_body
    assert unknown.resp_body == forbidden.resp_body

    for page_filter <- ["before=abc", "after=abc", "limit=1"] do
      invalid =
        get(ctx, "/api/wakes/#{carrier_id}/digest-members?#{page_filter}", ctx.admin_device.token)

      assert invalid.status == 400, page_filter
      assert JSON.decode!(invalid.resp_body)["error"]["code"] == "invalid_filter", page_filter
    end
  end

  defp schedule_wake(db, session_key, wake_id, prompt, due_at, class \\ "fyi") do
    input = %{
      session_key: session_key,
      origin: "agent:d2d_fixture",
      prompt: prompt,
      due_at: due_at,
      creator_session_key: session_key,
      class: class,
      wake_id: wake_id
    }

    seq = System.unique_integer([:positive, :monotonic])

    {:ok, _policy} =
      DB.transaction(db, fn txn ->
        Org.apply_notice_batching_lane_policy_in_txn(
          txn,
          input,
          true,
          "notice-batching-test-policy:d2:#{seq}",
          "user:policy-fixture",
          "rest-d2-fixture",
          seq
        )
      end)

    Wakes.schedule(db, input)
  end

  defp turn(db, session_key, wake_id, created_at) do
    seq = System.unique_integer([:positive, :monotonic])

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO turns (seq, sessionKey, messageId, wakeId, origin, prompt, status, createdAt)
        VALUES (?1, ?2, ?3, ?4, 'user:fixture', 'continue', 'delivered', ?5)
        """,
        [seq, session_key, "m_d2d_#{seq}", wake_id, created_at]
      )

    seq
  end

  defp coordination_dependency_version(db, session_key, from, to) do
    {:ok, turns} =
      DB.query(
        db,
        """
        SELECT seq, wakeId, createdAt, startedAt, endedAt
        FROM turns WHERE sessionKey=?1 AND createdAt>=?2 AND createdAt<?3
        """,
        [session_key, from, to]
      )

    turn_entries =
      Enum.map(turns, fn [seq, _wake_id, created_at, started_at, ended_at] ->
        {"turns", seq, natural_version([seq, created_at, started_at, ended_at])}
      end)

    wake_entries =
      turns
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.flat_map(fn wake_id ->
        {:ok, [[^wake_id, created_at, fired_at, canceled_at]]} =
          DB.query(
            db,
            "SELECT wakeId, createdAt, firedAt, canceledAt FROM wakes WHERE wakeId=?1",
            [wake_id]
          )

        [{"wakes", wake_id, natural_version([created_at, fired_at, canceled_at])}]
      end)

    {:ok, events} =
      DB.query(
        db,
        """
        SELECT seq FROM causal_events
        WHERE sessionKey=?1 AND kind='prod_fired' AND at>=?2 AND at<?3
        """,
        [session_key, from, to]
      )

    event_entries = Enum.map(events, fn [seq] -> {"causal events", seq, seq} end)
    dependency_digest(turn_entries ++ wake_entries ++ event_entries)
  end

  defp digest_dependency_version(db, wake_ids) do
    entries =
      wake_ids
      |> Enum.uniq()
      |> Enum.flat_map(fn wake_id ->
        {:ok, [[^wake_id, created_at, fired_at, canceled_at]]} =
          DB.query(
            db,
            "SELECT wakeId, createdAt, firedAt, canceledAt FROM wakes WHERE wakeId=?1",
            [wake_id]
          )

        [{"wakes", wake_id, natural_version([created_at, fired_at, canceled_at])}]
      end)

    dependency_digest(entries)
  end

  defp natural_version(values) do
    values |> Enum.filter(&is_integer/1) |> Enum.max()
  end

  defp dependency_digest(entries) do
    vector =
      entries
      |> Enum.map(fn {resource, key, version} -> [resource, key, version] end)
      |> Enum.sort_by(fn [resource, key, _version] -> {resource, JSON.encode!(key)} end)

    :crypto.hash(:sha256, JSON.encode!(vector)) |> Base.encode16(case: :lower)
  end

  defp user_principal(device), do: %{kind: "user", id: device.user_id, is_admin: device.is_admin}

  defp get(ctx, path, token) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(Router.init(ctx.opts))
  end
end
