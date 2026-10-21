defmodule Tightbeam.RestBulkSnapshotsRoutesTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{Archetypes, DB, Devices, Identity, Model, Org}
  alias Tightbeam.Firehose.Hub
  alias Tightbeam.Wire.Router

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-rest-bulk-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    :initialized = Identity.init!(base_dir)
    Archetypes.load!(base_dir)

    db = String.to_atom("rest_bulk_db_#{System.unique_integer([:positive])}")
    start_supervised!({DB, path: ":memory:", name: db})
    ensure_all_schemas(db)
    start_supervised!({Hub, name: Hub})

    Devices.add_user(db, "admin", true)
    Devices.add_user(db, "reader", false)
    Devices.add_user(db, "other", false)

    reader_session = ensure_main_session(db, "reader")
    other_session = ensure_main_session(db, "other")
    admin_session = ensure_main_session(db, "admin")

    reader_device = approved_device(db, "reader-device", "Reader", "reader")
    admin_device = approved_device(db, "admin-device", "Administrator", "admin")

    bulk_sessions =
      for index <- 1..40 do
        session!(
          db,
          "reader-worker-#{String.pad_leading(Integer.to_string(index), 2, "0")}",
          "reader"
        )
      end

    opts = [
      db: db,
      base_dir: base_dir,
      handlers: %{},
      cli_token: "tbc_rest_bulk",
      firehose_hub: Hub,
      session_status: fn _ -> nil end
    ]

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{
      db: db,
      opts: opts,
      reader_token: reader_device.token,
      admin_token: admin_device.token,
      org_token: "tbc_rest_bulk",
      reader_session: reader_session,
      other_session: other_session,
      admin_session: admin_session,
      bulk_sessions: bulk_sessions
    }
  end

  test "bulk wakes walk 1,200 visible rows across 40 sessions in three bounded pages", ctx do
    insert_wake_rows(ctx.db, ctx.bulk_sessions, 1_200)
    insert_wake(ctx.db, "wake-hidden", ctx.other_session.session_key, 2_000_000)

    default_page = get(ctx, "/api/wakes")
    assert default_page.status == 200, default_page.resp_body
    assert length(JSON.decode!(default_page.resp_body)["items"]) == 50

    first = get(ctx, "/api/wakes?limit=501&tail=false")
    first_page = JSON.decode!(first.resp_body)
    assert first.status == 200, first.resp_body
    assert length(first_page["items"]) == 500
    assert first_page["page"]["hasMoreAfter"]

    first_cursor = decode_cursor(first_page["page"]["newestCursor"])
    assert first_cursor["tuple"] == [1_000_500, wake_id(500)]

    second =
      get(ctx, "/api/wakes?limit=501&after=#{encode_cursor(first_page["page"]["newestCursor"])}")

    second_page = JSON.decode!(second.resp_body)
    assert second.status == 200, second.resp_body
    assert length(second_page["items"]) == 500
    assert second_page["page"]["hasMoreBefore"]
    assert second_page["page"]["hasMoreAfter"]

    before_second =
      get(
        ctx,
        "/api/wakes?limit=501&before=#{encode_cursor(second_page["page"]["oldestCursor"])}"
      )

    before_second_page = JSON.decode!(before_second.resp_body)
    assert before_second.status == 200, before_second.resp_body

    assert Enum.map(before_second_page["items"], & &1["wakeId"]) ==
             Enum.map(1..500, &wake_id/1)

    third =
      get(
        ctx,
        "/api/wakes?limit=501&after=#{encode_cursor(second_page["page"]["newestCursor"])}"
      )

    third_page = JSON.decode!(third.resp_body)
    assert third.status == 200, third.resp_body
    assert length(third_page["items"]) == 200
    assert third_page["page"]["hasMoreBefore"]
    refute third_page["page"]["hasMoreAfter"]

    ids =
      (first_page["items"] ++ second_page["items"] ++ third_page["items"])
      |> Enum.map(& &1["wakeId"])

    assert ids == Enum.map(1..1_200, &wake_id/1)
    assert length(Enum.uniq(ids)) == 1_200
    refute "wake-hidden" in ids
  end

  test "assignment and turn bulk pages use their complete canonical order tuples", ctx do
    insert_assignment(ctx.db, "assignment-a", ctx.reader_session.session_key, "reader", 700)
    insert_assignment(ctx.db, "assignment-b", ctx.reader_session.session_key, "reader", 700)
    insert_assignment(ctx.db, "assignment-c", ctx.reader_session.session_key, "reader", 701)
    insert_assignment(ctx.db, "assignment-hidden", ctx.other_session.session_key, "other", 702)

    first_assignments = get(ctx, "/api/assignments?limit=2&tail=false")
    assignment_page = JSON.decode!(first_assignments.resp_body)
    assert first_assignments.status == 200, first_assignments.resp_body
    assert Enum.map(assignment_page["items"], & &1["id"]) == ["assignment-a", "assignment-b"]

    assignment_cursor = decode_cursor(assignment_page["page"]["newestCursor"])
    assert assignment_cursor["tuple"] == [700, "assignment-b"]

    next_assignments =
      get(
        ctx,
        "/api/assignments?limit=2&after=#{encode_cursor(assignment_page["page"]["newestCursor"])}"
      )

    next_assignment_page = JSON.decode!(next_assignments.resp_body)
    assert next_assignments.status == 200, next_assignments.resp_body
    assert Enum.map(next_assignment_page["items"], & &1["id"]) == ["assignment-c"]

    before_assignment_page =
      get(
        ctx,
        "/api/assignments?limit=2&before=#{encode_cursor(next_assignment_page["page"]["oldestCursor"])}"
      )

    assert Enum.map(JSON.decode!(before_assignment_page.resp_body)["items"], & &1["id"]) == [
             "assignment-a",
             "assignment-b"
           ]

    insert_turn(ctx.db, 101, ctx.reader_session.session_key, 900)
    insert_turn(ctx.db, 102, ctx.reader_session.session_key, 901)
    insert_turn(ctx.db, 103, ctx.reader_session.session_key, 902)
    insert_turn(ctx.db, 104, ctx.other_session.session_key, 903)

    first_turns = get(ctx, "/api/turns?limit=2&tail=false")
    turn_page = JSON.decode!(first_turns.resp_body)
    assert first_turns.status == 200, first_turns.resp_body
    assert Enum.map(turn_page["items"], & &1["seq"]) == [101, 102]
    assert decode_cursor(turn_page["page"]["newestCursor"])["tuple"] == [102]

    next_turns =
      get(
        ctx,
        "/api/turns?limit=2&after=#{encode_cursor(turn_page["page"]["newestCursor"])}"
      )

    next_turn_page = JSON.decode!(next_turns.resp_body)
    assert next_turns.status == 200, next_turns.resp_body
    assert Enum.map(next_turn_page["items"], & &1["seq"]) == [103]

    before_turn_page =
      get(
        ctx,
        "/api/turns?limit=2&before=#{encode_cursor(next_turn_page["page"]["oldestCursor"])}"
      )

    assert Enum.map(JSON.decode!(before_turn_page.resp_body)["items"], & &1["seq"]) == [101, 102]

    for index <- 1..55 do
      insert_assignment(
        ctx.db,
        "assignment-default-#{index}",
        ctx.reader_session.session_key,
        "reader",
        1_000 + index
      )

      insert_turn(ctx.db, 200 + index, ctx.reader_session.session_key, 2_000 + index)
    end

    assert length(JSON.decode!(get(ctx, "/api/assignments").resp_body)["items"]) == 50
    assert length(JSON.decode!(get(ctx, "/api/turns").resp_body)["items"]) == 50

    reader_assignment_items =
      get(ctx, "/api/assignments?limit=500&tail=false")
      |> then(&JSON.decode!(&1.resp_body)["items"])

    reader_turn_items =
      get(ctx, "/api/turns?limit=500&tail=false")
      |> then(&JSON.decode!(&1.resp_body)["items"])

    refute "assignment-hidden" in Enum.map(reader_assignment_items, & &1["id"])
    refute 104 in Enum.map(reader_turn_items, & &1["seq"])

    admin_assignments = get(ctx, "/api/assignments?tail=false", ctx.admin_token)
    admin_turns = get(ctx, "/api/turns?tail=false", ctx.admin_token)

    assert "assignment-hidden" in Enum.map(
             JSON.decode!(admin_assignments.resp_body)["items"],
             & &1["id"]
           )

    assert 104 in Enum.map(JSON.decode!(admin_turns.resp_body)["items"], & &1["seq"])
  end

  defp approved_device(db, device_id, name, user_id) do
    {:pending, _device} =
      Devices.pair(db, %{device_id: device_id, claimed_name: name, platform: nil, model: nil})

    Devices.approve(db, device_id, user_id)
  end

  defp session!(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp insert_assignment(db, id, holder, opener, opened_at) do
    assert {:ok, []} =
             DB.query(
               db,
               "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt) " <>
                 "VALUES (?1, ?2, ?3, ?4, ?5)",
               [id, id, holder, opener, opened_at]
             )
  end

  defp insert_turn(db, seq, session_key, created_at) do
    assert {:ok, []} =
             DB.query(
               db,
               "INSERT INTO turns (seq, sessionKey, messageId, origin, prompt, status, createdAt) " <>
                 "VALUES (?1, ?2, ?3, 'user:reader', 'prompt', 'delivered', ?4)",
               [seq, session_key, "message-#{seq}", created_at]
             )
  end

  defp insert_wake_rows(db, sessions, count) do
    Enum.each(1..count |> Enum.chunk_every(100), fn chunk ->
      values = Enum.map_join(chunk, ",", fn _ -> "(?, ?, 'user:reader', ?, ?, ?)" end)

      params =
        Enum.flat_map(chunk, fn seq ->
          session = Enum.at(sessions, rem(seq - 1, length(sessions)))
          [wake_id(seq), session.session_key, "Prompt #{seq}", 1_000_000 + seq, 1_000_000 + seq]
        end)

      assert {:ok, []} =
               DB.query(
                 db,
                 "INSERT INTO wakes (wakeId, sessionKey, origin, prompt, dueAt, createdAt) " <>
                   "VALUES " <> values,
                 params
               )
    end)
  end

  defp insert_wake(db, id, session_key, created_at) do
    assert {:ok, []} =
             DB.query(
               db,
               "INSERT INTO wakes (wakeId, sessionKey, origin, prompt, dueAt, createdAt) " <>
                 "VALUES (?1, ?2, 'user:other', 'Hidden prompt', ?3, ?3)",
               [id, session_key, created_at]
             )
  end

  defp get(ctx, path, token \\ nil) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{token || ctx.reader_token}")
    |> Router.call(Router.init(ctx.opts))
  end

  defp wake_id(seq), do: "wake-#{String.pad_leading(Integer.to_string(seq), 4, "0")}"

  defp decode_cursor(cursor) do
    cursor |> Base.url_decode64!(padding: false) |> JSON.decode!()
  end

  defp encode_cursor(cursor), do: URI.encode_www_form(cursor)
end
