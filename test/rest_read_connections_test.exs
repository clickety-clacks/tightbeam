defmodule Tightbeam.RestReadConnectionsTest do
  # wi_0b608f33: REST reads of a session (its history, its detail, its tool
  # calls) only read. They must run on the database's read connections, so a
  # slow history load cannot hold the single writer, and a busy writer cannot
  # hold the reads. These run on a file-backed database, the only kind with
  # read connections.
  use Tightbeam.TestCase, async: false
  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{DB, Devices, Ledger, Model, Org, Projection, StateResources}
  alias Tightbeam.Wire.Router

  setup do
    base_dir =
      System.tmp_dir!()
      |> Path.join("tightbeam-rest-read-connections-#{System.unique_integer([:positive])}")
      |> Tightbeam.LiveBaseAdmission.canonical!()

    File.mkdir_p!(base_dir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    payload_root = Path.join(base_dir, "payload")
    File.mkdir_p!(Path.join(payload_root, "ebin"))
    File.mkdir_p!(Path.join(payload_root, "priv"))
    File.write!(Path.join(payload_root, "priv/rest-read-connections"), "test payload")

    {:ok, manifest} =
      Tightbeam.LiveBaseGuard.generate_manifest(Tightbeam.LiveBasePayload.files!(payload_root))

    File.write!(Path.join(payload_root, "build-manifest.json"), JSON.encode!(manifest))

    db =
      start_supervised!(
        Supervisor.child_spec(
          {DB,
           path: Path.join(base_dir, "state.db"),
           name: nil,
           guard_inputs: [],
           payload_root: payload_root},
          id: {:rest_read_connections, System.unique_integer([:positive])}
        )
      )

    :ok = ensure_all_schemas(db)

    {:paired, device} =
      Devices.pair(db, %{device_id: "d1", claimed_name: "Flynn", platform: nil, model: nil})

    session =
      Org.create(db, %{
        session_key: "history-reader",
        display_name: "history-reader",
        owner_user_id: device.user_id,
        origin: "user:#{device.user_id}",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    for n <- 1..3 do
      {:appended, _} =
        Projection.append(db, %{
          session_key: session.session_key,
          role: "user",
          content: "message #{n}"
        })
    end

    opts = [
      db: db,
      base_dir: base_dir,
      handlers: %{},
      cli_token: "tbc_test",
      session_status: fn _ -> nil end
    ]

    %{db: db, device: device, session: session, opts: opts}
  end

  test "session history, detail and tool calls answer while the database writer is busy",
       ctx do
    parent = self()

    writer =
      Task.async(fn ->
        DB.transaction(ctx.db, fn _txn ->
          send(parent, {:writer_held, self()})

          receive do
            :release -> :released
          after
            15_000 -> raise "writer was not released"
          end
        end)
      end)

    assert_receive {:writer_held, owner}, 5_000
    key = ctx.session.session_key

    reads =
      Task.async(fn ->
        %{
          observer_sequences: get(ctx, "/api/session-message-sequences", "tbc_test"),
          user_sequences: get(ctx, "/api/session-message-sequences", ctx.device.token),
          observer_history: get(ctx, "/api/sessions/#{key}/messages", "tbc_test"),
          user_history: get(ctx, "/api/sessions/#{key}/messages", ctx.device.token),
          detail: get(ctx, "/api/sessions/#{key}", ctx.device.token),
          tool_calls: get(ctx, "/api/sessions/#{key}/tool-calls", ctx.device.token)
        }
      end)

    answered = Task.yield(reads, 5_000)
    send(owner, :release)
    assert {:ok, :released} = Task.await(writer, 5_000)
    assert {:ok, responses} = answered || {:after_writer, Task.await(reads, 30_000)}

    for name <- [:observer_history, :user_history] do
      response = responses[name]
      assert response.status == 200, "#{name}: #{response.resp_body}"

      assert Enum.map(JSON.decode!(response.resp_body)["items"], & &1["content"]) ==
               ["message 1", "message 2", "message 3"]
    end

    [_, _, latest] = StateResources.query_messages_for_session(ctx.db, key)

    for name <- [:observer_sequences, :user_sequences] do
      response = responses[name]
      assert response.status == 200, response.resp_body

      assert %{"sessionKey" => key, "latestMessageSeq" => latest.seq} in JSON.decode!(
               response.resp_body
             )["items"]
    end

    assert responses.detail.status == 200, responses.detail.resp_body
    assert JSON.decode!(responses.detail.resp_body)["item"]["sessionKey"] == key
    assert responses.tool_calls.status == 200, responses.tool_calls.resp_body
    assert JSON.decode!(responses.tool_calls.resp_body)["items"] == []
  end

  test "the other REST read resources answer while the database writer is busy", ctx do
    key = ctx.session.session_key

    {:ok, [[message_id]]} =
      DB.query(ctx.db, "SELECT id FROM messages WHERE sessionKey=?1 ORDER BY seq LIMIT 1", [key])

    paths = [
      "/api/sessions",
      "/api/sessions/#{key}/messages/#{message_id}",
      "/api/sessions/#{key}/tool-calls/tc_missing",
      "/api/wakes/w_missing",
      "/api/turns/1",
      "/api/artifacts",
      "/api/artifacts/art_missing",
      "/api/attests",
      "/api/attests/att_missing",
      "/api/assignments/asg_missing/attests",
      "/api/read-markers",
      "/api/read-markers/scope_missing",
      "/api/roles/role-missing",
      "/api/facts/1",
      "/api/critical-state/#{key}",
      "/api/devices/d1",
      "/api/decision-requests/dr_missing"
    ]

    parent = self()

    writer =
      Task.async(fn ->
        DB.transaction(ctx.db, fn _txn ->
          send(parent, {:writer_held, self()})

          receive do
            :release -> :released
          after
            30_000 -> raise "writer was not released"
          end
        end)
      end)

    assert_receive {:writer_held, owner}, 5_000

    reads =
      Task.async(fn ->
        Map.new(paths, fn path -> {path, get(ctx, path, ctx.device.token)} end)
      end)

    answered = Task.yield(reads, 10_000)
    send(owner, :release)
    assert {:ok, :released} = Task.await(writer, 5_000)
    assert {:ok, responses} = answered || {:after_writer, Task.await(reads, 60_000)}

    for path <- paths do
      response = responses[path]
      assert response.status in [200, 404], "#{path}: #{response.status} #{response.resp_body}"
    end

    assert responses["/api/sessions/#{key}/messages/#{message_id}"].status == 200
    assert responses["/api/sessions"].status == 200
  end

  test "bulk sequence query uses one indexed seek per session without scanning history", ctx do
    principal = %{kind: "observer", id: "observer", is_admin: false, core_detail_trace: self()}
    StateResources.query_session_message_sequences(ctx.db, principal)
    assert [{sql, params}] = traced_queries([])
    {:ok, plan} = DB.query(ctx.db, "EXPLAIN QUERY PLAN " <> sql, params)
    details = Enum.map(plan, &List.last/1)

    assert Enum.any?(
             details,
             &String.contains?(&1, "SEARCH m USING COVERING INDEX messages_session")
           )

    refute Enum.any?(details, &Regex.match?(~r/SCAN (m|messages)\b/, &1))
  end

  test "a read right after a committed write sees the write", ctx do
    key = ctx.session.session_key

    for n <- 4..8 do
      {:appended, _} =
        Projection.append(ctx.db, %{session_key: key, role: "user", content: "message #{n}"})

      response = get(ctx, "/api/sessions/#{key}/messages?limit=1", ctx.device.token)
      assert response.status == 200, response.resp_body
      assert [%{"content" => content}] = JSON.decode!(response.resp_body)["items"]
      assert content == "message #{n}"
    end
  end

  test "a reader deadline returns a retryable HTTP 503", ctx do
    response =
      Tightbeam.Wire.RequestObservation.call(
        conn(:get, "/api/sessions/history-reader/messages"),
        fn _conn ->
          DB.read_transaction!(ctx.db, fn txn ->
            DB.Txn.q(%{txn | deadline: System.monotonic_time(:millisecond) - 1}, "SELECT 1")
          end)
        end
      )

    assert response.status == 503

    assert %{
             "error" => %{
               "code" => "db_timeout",
               "action" => "retry_safe",
               "timeoutSource" => "reader_deadline",
               "effectState" => "none"
             }
           } =
             JSON.decode!(response.resp_body)
  end

  test "history pages preserve event ids, ordering and flags with cancellation members", ctx do
    key = ctx.session.session_key
    [first | _] = StateResources.query_messages_for_session(ctx.db, key)

    {:ok, turn} =
      Ledger.enqueue(ctx.db, %{
        session_key: key,
        message_id: first.id,
        origin: "process:test",
        prompt: "history fixture"
      })

    :ok = execute!(ctx.db, "UPDATE turns SET wakeId='history-carrier' WHERE seq=?1", [turn])

    :ok =
      execute!(ctx.db, "UPDATE messages SET recordEventIds=?2 WHERE id=?1", [
        first.id,
        JSON.encode!(["z", "a"])
      ])

    :ok =
      execute!(
        ctx.db,
        """
        INSERT INTO wakes(wakeId, sessionKey, origin, prompt, dueAt, createdAt, recordEventIds)
        VALUES ('history-carrier', ?1, 'process:test', 'carrier', 1, 1, '["b","a"]'),
               ('history-member', ?1, 'process:test', 'member', 1, 1, '["c","b"]')
        """,
        [key]
      )

    {:appended, reply} =
      Projection.append(ctx.db, %{
        session_key: key,
        role: "assistant",
        content: "reply",
        reply_to_message_id: first.id
      })

    assert StateResources.query_message(ctx.db, first.id).record_event_ids == ["a", "b", "z"]
    assert_pages_match_full_history(ctx.db, key)
    drop_cancellation_fixture_guards(ctx.db)
    insert_cancellations(ctx.db, "history-member", "history-carrier")
    assert_pages_match_full_history(ctx.db, key)
    page = StateResources.query_messages_for_session_page(ctx.db, key, :earliest, 1)
    assert hd(page.rows).record_event_ids == ["a", "b", "c", "z"]
    assert StateResources.query_message(ctx.db, first.id).record_event_ids == ["a", "b", "c", "z"]
    assert StateResources.query_message(ctx.db, reply.id).record_event_ids == ["a", "b", "c"]
  end

  test "history page scans cancellation rows at most once outside per-message subqueries", ctx do
    drop_cancellation_fixture_guards(ctx.db)

    :ok =
      execute!(
        ctx.db,
        """
        WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<2000)
        INSERT INTO wakes(wakeId, sessionKey, origin, prompt, dueAt, createdAt)
        SELECT 'unrelated-' || x, ?1, 'process:test', 'unrelated', 1, 1 FROM n
        """,
        [ctx.session.session_key]
      )

    :ok =
      execute!(ctx.db, """
      INSERT INTO wake_cancellations(wakeId,canceledAt,requesterKind,requesterId,reasonKind,
        causalSourceKind,causalSourceId,outcomeKind,replacementWakeId,workImpactKind,actionNeeded)
      SELECT wakeId,1,'process','tightbeam:batcher','superseded','wake','cause','replacement',
        'unrelated-1','no_linked_work',0 FROM wakes WHERE wakeId LIKE 'unrelated-%' AND wakeId != 'unrelated-1'
      """)

    [first | _] = StateResources.query_messages_for_session(ctx.db, ctx.session.session_key)

    {:ok, turn} =
      Ledger.enqueue(ctx.db, %{
        session_key: ctx.session.session_key,
        message_id: first.id,
        origin: "process:test",
        prompt: "plan fixture"
      })

    :ok = execute!(ctx.db, "UPDATE turns SET wakeId='unrelated-1' WHERE seq=?1", [turn])
    parent = self()

    DB.read_transaction!(ctx.db, fn txn ->
      txn = DB.Txn.observe_queries(txn, parent)
      StateResources.query_messages_for_session_page(txn, ctx.session.session_key, :latest, 500)
    end)

    statements = traced_queries([])
    assert statements != []

    plans =
      Enum.map(statements, fn {sql, params} ->
        {:ok, rows} = DB.query(ctx.db, "EXPLAIN QUERY PLAN " <> sql, params)
        rows
      end)

    cancellation_scans =
      for plan <- plans,
          [id, parent, _, detail] <- plan,
          Regex.match?(~r/SCAN (cancellation|wake_cancellations)\b/, detail),
          do: {plan, id, parent}

    assert length(cancellation_scans) <= 1

    for {plan, _id, parent} <- cancellation_scans do
      refute correlated_ancestor?(plan, parent)
    end
  end

  defp correlated_ancestor?(_plan, 0), do: false

  defp correlated_ancestor?(plan, id) do
    case Enum.find(plan, &(hd(&1) == id)) do
      [_, parent, _, detail] ->
        String.contains?(detail, "CORRELATED") or correlated_ancestor?(plan, parent)

      nil ->
        false
    end
  end

  defp traced_queries(acc) do
    receive do
      {:core_detail_trace, {:sql_query, sql, params}} -> traced_queries([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_pages_match_full_history(db, key) do
    all = StateResources.query_messages_for_session(db, key)

    for {boundary, expected, before?, after?} <- [
          {:earliest, Enum.take(all, 2), false, length(all) > 2},
          {:latest, Enum.take(all, -2), length(all) > 2, false},
          {{:after, [hd(all).seq]}, Enum.slice(all, 1, 2), true, length(all) > 3},
          {{:before, [List.last(all).seq]}, all |> Enum.drop(-1) |> Enum.take(-2),
           length(all) > 3, true}
        ] do
      page = StateResources.query_messages_for_session_page(db, key, boundary, 2)
      assert page.rows == expected
      assert page.flags.has_more_before == before?
      assert page.flags.has_more_after == after?
    end
  end

  # Synthetic cancellation fixtures exercise reads, independently of cancellation admission.
  defp drop_cancellation_fixture_guards(db) do
    :ok = DB.execute(db, "PRAGMA foreign_keys=OFF")

    {:ok, triggers} =
      DB.query(
        db,
        "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='wake_cancellations'"
      )

    for [name] <- triggers, do: execute!(db, ~s(DROP TRIGGER "#{name}"))
  end

  defp insert_cancellations(db, member, carrier) do
    :ok =
      execute!(
        db,
        """
        INSERT INTO wake_cancellations(wakeId,canceledAt,requesterKind,requesterId,reasonKind,
          causalSourceKind,causalSourceId,outcomeKind,replacementWakeId,workImpactKind,actionNeeded)
        VALUES (?1,1,'process','tightbeam:batcher','superseded','wake','cause','replacement',?2,'no_linked_work',0)
        """,
        [member, carrier]
      )
  end

  defp execute!(db, sql, params \\ []) do
    {:ok, _} = DB.query(db, sql, params)
    :ok
  end

  defp get(ctx, path, bearer) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> Router.call(Router.init(ctx.opts))
  end
end
